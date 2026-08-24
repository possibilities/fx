//! Process-lifetime Git worktree discovery for the ADE event feed.
//!
//! Tool execution only enqueues exact edited paths. One background worker owns
//! canonical Git-root discovery, first-seen ordering, checkpoint replacement,
//! and event publication so none of that I/O delays agent work.

const std = @import("std");
const builtin = @import("builtin");
const hooks = @import("../../core/hooks/hooks.zig");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const tool_runtime = @import("../../core/tooling/tool_runtime.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const max_queued_observations: usize = 128;
const max_queued_observation_bytes: usize = 1024 * 1024;
const max_gitdir_marker_bytes: usize = 4096;

pub const DiscoveryReason = enum {
    launch_directory,
    file_mutation,
    terminal_write,
    subagent_file_mutation,
    subagent_terminal_write,

    pub fn wireName(self: DiscoveryReason) []const u8 {
        return switch (self) {
            .launch_directory => "launch_directory",
            .file_mutation => "file_mutation",
            .terminal_write => "terminal_write",
            .subagent_file_mutation => "subagent_file_mutation",
            .subagent_terminal_write => "subagent_terminal_write",
        };
    }
};

pub const Discovery = struct {
    root: []const u8,
    revision: u64,
    reason: DiscoveryReason,
    scope: hooks.Scope,
    parent_session_id: ?[]const u8 = null,
};

pub const EventSink = struct {
    context: *anyopaque,
    report_fn: *const fn (*anyopaque, Discovery) void,

    fn report(self: EventSink, discovery: Discovery) void {
        self.report_fn(self.context, discovery);
    }
};

const PathKind = enum { file, directory };

const QueuedObservation = struct {
    node: std.DoublyLinkedList.Node = .{},
    path: []u8,
    kind: PathKind,
    reason: DiscoveryReason,
    scope: hooks.Scope,
    parent_session_id: ?[]u8,
    charge: usize,

    fn deinit(self: QueuedObservation, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(@constCast(self.scope.workspace_root));
        if (self.scope.session_id) |session_id| alloc.free(@constCast(session_id));
        if (self.parent_session_id) |parent_session_id| alloc.free(parent_session_id);
    }
};

pub const Tracker = struct {
    enabled: bool = false,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    alloc: ?std.mem.Allocator = null,
    instance_id: []u8 = &.{},
    checkpoint_path: []u8 = &.{},
    event_sink: ?EventSink = null,
    queue: std.DoublyLinkedList = .{},
    queue_len: usize = 0,
    queued_bytes: usize = 0,
    in_flight: bool = false,
    stopping: bool = false,
    worker_thread: ?std.Thread = null,
    roots: std.ArrayList([]u8) = .empty,
    revision: u64 = 0,

    pub fn init(
        self: *Tracker,
        alloc: std.mem.Allocator,
        instance_id: []const u8,
        checkpoint_path: ?[]const u8,
        event_sink: ?EventSink,
        launch_scope: hooks.Scope,
    ) !void {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
        const checkpoint = checkpoint_path orelse "";
        if (instance_id.len == 0 or (checkpoint.len == 0 and event_sink == null)) return;

        const instance_copy = try alloc.dupe(u8, instance_id);
        errdefer alloc.free(instance_copy);
        const checkpoint_copy = try alloc.dupe(u8, checkpoint);
        errdefer alloc.free(checkpoint_copy);

        self.* = .{
            .alloc = alloc,
            .instance_id = instance_copy,
            .checkpoint_path = checkpoint_copy,
            .event_sink = event_sink,
        };
        self.enabled = true;
        self.enqueueBatch(
            launch_scope,
            null,
            .launch_directory,
            .directory,
            &.{launch_scope.workspace_root},
        );
        self.worker_thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.enabled = false;
            self.clearQueue();
            self.freeConfiguration();
            self.* = .{};
            return err;
        };
    }

    pub fn deinit(self: *Tracker) void {
        if (!self.enabled) {
            self.freeConfiguration();
            self.* = .{};
            return;
        }
        const alloc = self.alloc orelse {
            self.* = .{};
            return;
        };
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.clearQueueLocked(alloc);
        self.wake.broadcast(io);
        self.mutex.unlock(io);
        if (self.worker_thread) |thread| thread.join();

        for (self.roots.items) |root| alloc.free(root);
        self.roots.deinit(alloc);
        self.freeConfiguration();
        self.* = .{};
    }

    pub fn reportEditedPaths(
        self: *Tracker,
        observation: tool_runtime.EditedPathObservation,
    ) void {
        const reason: DiscoveryReason = switch (observation.scope.kind) {
            .subagent => switch (observation.source) {
                .file_mutation => .subagent_file_mutation,
                .terminal_write => .subagent_terminal_write,
            },
            .interactive => switch (observation.source) {
                .file_mutation => .file_mutation,
                .terminal_write => .terminal_write,
            },
            .ask, .acp => return,
        };
        self.enqueueBatch(
            observation.scope,
            observation.parent_session_id,
            reason,
            switch (observation.source) {
                .file_mutation => .file,
                .terminal_write => .directory,
            },
            observation.paths,
        );
    }

    fn enqueueBatch(
        self: *Tracker,
        scope: hooks.Scope,
        parent_session_id: ?[]const u8,
        reason: DiscoveryReason,
        kind: PathKind,
        paths: []const []const u8,
    ) void {
        if (!self.enabled) return;
        const alloc = self.alloc orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping) return;

        for (paths) |path| {
            if (path.len == 0) continue;
            const charge = observationCharge(path, scope, parent_session_id);
            if (self.queue_len == max_queued_observations or
                charge > max_queued_observation_bytes -| self.queued_bytes)
            {
                debug_trace.logf("ade_git_roots", "observation dropped reason=queue_full", .{});
                continue;
            }
            const owned_path = alloc.dupe(u8, path) catch {
                debug_trace.logf("ade_git_roots", "observation dropped reason=out_of_memory", .{});
                break;
            };
            const owned_workspace = alloc.dupe(u8, scope.workspace_root) catch {
                alloc.free(owned_path);
                debug_trace.logf("ade_git_roots", "observation dropped reason=out_of_memory", .{});
                break;
            };
            const owned_session = if (scope.session_id) |session_id|
                alloc.dupe(u8, session_id) catch {
                    alloc.free(owned_workspace);
                    alloc.free(owned_path);
                    debug_trace.logf("ade_git_roots", "observation dropped reason=out_of_memory", .{});
                    break;
                }
            else
                null;
            const owned_parent_session = if (parent_session_id) |parent_id|
                alloc.dupe(u8, parent_id) catch {
                    if (owned_session) |session_id| alloc.free(session_id);
                    alloc.free(owned_workspace);
                    alloc.free(owned_path);
                    debug_trace.logf("ade_git_roots", "observation dropped reason=out_of_memory", .{});
                    break;
                }
            else
                null;
            const queued = alloc.create(QueuedObservation) catch {
                if (owned_parent_session) |parent_id| alloc.free(parent_id);
                if (owned_session) |session_id| alloc.free(session_id);
                alloc.free(owned_workspace);
                alloc.free(owned_path);
                debug_trace.logf("ade_git_roots", "observation dropped reason=out_of_memory", .{});
                break;
            };
            queued.* = .{
                .path = owned_path,
                .kind = kind,
                .reason = reason,
                .scope = .{
                    .kind = scope.kind,
                    .workspace_root = owned_workspace,
                    .session_id = owned_session,
                    .subagent_id = scope.subagent_id,
                },
                .parent_session_id = owned_parent_session,
                .charge = charge,
            };
            self.queue.append(&queued.node);
            self.queue_len += 1;
            self.queued_bytes += charge;
        }
        if (self.queue.first != null) self.wake.signal(io);
    }

    fn workerMain(self: *Tracker) void {
        const alloc = self.alloc orelse return;
        const io = io_mod.getIo();
        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.queue.first == null and !self.stopping) {
                self.wake.waitUncancelable(io, &self.mutex);
            }
            if (self.stopping) {
                self.mutex.unlock(io);
                return;
            }
            const observation = self.takeLocked().?;
            self.in_flight = true;
            self.mutex.unlock(io);
            self.processObservation(observation);
            observation.deinit(alloc);
            alloc.destroy(observation);

            self.mutex.lockUncancelable(io);
            self.in_flight = false;
            self.wake.broadcast(io);
            self.mutex.unlock(io);
        }
    }

    fn processObservation(self: *Tracker, queued: *QueuedObservation) void {
        const alloc = self.alloc orelse return;
        const maybe_root = discoverGitRoot(alloc, queued.path, queued.kind) catch |err| {
            debug_trace.logf("ade_git_roots", "discovery failed err={s}", .{@errorName(err)});
            if (queued.reason == .launch_directory) self.replaceInitialEmptyCheckpoint();
            return;
        };
        const root = maybe_root orelse {
            if (queued.reason == .launch_directory) self.replaceInitialEmptyCheckpoint();
            return;
        };
        if (self.containsRoot(root)) {
            alloc.free(root);
            return;
        }
        self.roots.append(alloc, root) catch {
            alloc.free(root);
            return;
        };
        self.revision += 1;

        if (self.checkpoint_path.len > 0) {
            self.replaceCheckpoint() catch |err| {
                debug_trace.logf(
                    "ade_git_roots",
                    "checkpoint replace failed revision={d} err={s}",
                    .{ self.revision, @errorName(err) },
                );
            };
        }
        if (self.event_sink) |sink| sink.report(.{
            .root = root,
            .revision = self.revision,
            .reason = queued.reason,
            .scope = queued.scope,
            .parent_session_id = queued.parent_session_id,
        });
    }

    fn takeLocked(self: *Tracker) ?*QueuedObservation {
        const node = self.queue.popFirst() orelse return null;
        const observation: *QueuedObservation = @fieldParentPtr("node", node);
        self.queue_len -= 1;
        self.queued_bytes -= observation.charge;
        return observation;
    }

    fn clearQueue(self: *Tracker) void {
        const alloc = self.alloc orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clearQueueLocked(alloc);
    }

    fn clearQueueLocked(self: *Tracker, alloc: std.mem.Allocator) void {
        while (self.takeLocked()) |observation| {
            observation.deinit(alloc);
            alloc.destroy(observation);
        }
        self.queue_len = 0;
        self.queued_bytes = 0;
    }

    fn waitUntilIdle(self: *Tracker) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.queue_len > 0 or self.in_flight) {
            self.wake.waitUncancelable(io, &self.mutex);
        }
    }

    fn containsRoot(self: *const Tracker, candidate: []const u8) bool {
        for (self.roots.items) |root| {
            if (std.mem.eql(u8, root, candidate)) return true;
        }
        return false;
    }

    fn replaceInitialEmptyCheckpoint(self: *Tracker) void {
        if (self.checkpoint_path.len == 0 or self.revision != 0) return;
        self.replaceCheckpoint() catch |err| {
            debug_trace.logf(
                "ade_git_roots",
                "initial checkpoint replace failed err={s}",
                .{@errorName(err)},
            );
        };
    }

    fn replaceCheckpoint(self: *Tracker) !void {
        const alloc = self.alloc.?;
        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        try std.json.Stringify.value(.{
            .schema = @as(u8, 1),
            .instance_id = self.instance_id,
            .revision = self.revision,
            .git_roots = self.roots.items,
        }, .{}, &output.writer);
        try output.writer.writeByte('\n');
        try replacePrivateFileAtomic(
            alloc,
            self.checkpoint_path,
            output.written(),
            self.revision,
        );
    }

    fn freeConfiguration(self: *Tracker) void {
        const alloc = self.alloc orelse return;
        if (self.instance_id.len > 0) alloc.free(self.instance_id);
        if (self.checkpoint_path.len > 0) alloc.free(self.checkpoint_path);
    }
};

fn observationCharge(
    path: []const u8,
    scope: hooks.Scope,
    parent_session_id: ?[]const u8,
) usize {
    var total: usize = @sizeOf(QueuedObservation);
    total +|= path.len;
    total +|= scope.workspace_root.len;
    if (scope.session_id) |session_id| total +|= session_id.len;
    if (parent_session_id) |parent_id| total +|= parent_id.len;
    return total;
}

fn discoverGitRoot(
    alloc: std.mem.Allocator,
    path: []const u8,
    kind: PathKind,
) !?[]u8 {
    const start = switch (kind) {
        .directory => path,
        .file => std.fs.path.dirname(path) orelse return null,
    };
    var current = try io_mod.realpathAlloc(alloc, start);
    errdefer alloc.free(current);

    while (true) {
        const marker = try std.fs.path.join(alloc, &.{ current, ".git" });
        defer alloc.free(marker);
        if (std.Io.Dir.cwd().statFile(io_mod.getIo(), marker, .{
            .follow_symlinks = false,
        })) |stat| {
            if (stat.kind == .directory) return current;
            if (stat.kind == .file and try validGitDirMarker(
                alloc,
                current,
                marker,
            )) return current;
        } else |_| {}

        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == current.len and std.mem.eql(u8, parent, current)) break;
        const next = try alloc.dupe(u8, parent);
        alloc.free(current);
        current = next;
    }
    alloc.free(current);
    return null;
}

fn validGitDirMarker(
    alloc: std.mem.Allocator,
    checkout_root: []const u8,
    marker_path: []const u8,
) !bool {
    const io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(io, marker_path, .{}) catch return false;
    defer file.close(io);
    const bytes = io_mod.readFileToEnd(alloc, &file, max_gitdir_marker_bytes) catch
        return false;
    defer alloc.free(bytes);

    const line = std.mem.trimEnd(u8, bytes, "\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, line, prefix)) return false;
    const raw_target = std.mem.trim(u8, line[prefix.len..], " \t");
    if (raw_target.len == 0 or
        std.mem.findScalar(u8, raw_target, '\n') != null or
        std.mem.findScalar(u8, raw_target, '\r') != null) return false;

    const candidate = if (std.fs.path.isAbsolute(raw_target))
        try alloc.dupe(u8, raw_target)
    else
        try std.fs.path.join(alloc, &.{ checkout_root, raw_target });
    defer alloc.free(candidate);
    const canonical = io_mod.realpathAlloc(alloc, candidate) catch return false;
    defer alloc.free(canonical);
    const stat = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch return false;
    return stat.kind == .directory;
}

fn replacePrivateFileAtomic(
    alloc: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    revision: u64,
) !void {
    const temp_path = try std.fmt.allocPrint(
        alloc,
        "{s}.tmp.{d}.{d}",
        .{ path, revision, io_mod.nanoTimestamp() },
    );
    defer alloc.free(temp_path);

    var cleanup_temp = true;
    defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), temp_path) catch {};
    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), temp_path, .{
            .exclusive = true,
            .permissions = private_file_permissions,
        });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), bytes);
        try file.sync(io_mod.getIo());
    }
    try std.Io.Dir.renameAbsolute(temp_path, path, io_mod.getIo());
    cleanup_temp = false;
}

const OutsideGitTmp = struct {
    dir: std.Io.Dir,
    parent: std.Io.Dir,
    name: [96]u8,
    name_len: usize,

    fn init() !OutsideGitTmp {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            return error.SkipZigTest;
        }
        var parent = try std.Io.Dir.openDirAbsolute(std.testing.io, "/tmp", .{});
        errdefer parent.close(std.testing.io);
        var name: [96]u8 = undefined;
        const rendered = try std.fmt.bufPrint(
            &name,
            "fx-ade-git-roots-{d}",
            .{io_mod.nanoTimestamp()},
        );
        const dir = try parent.createDirPathOpen(std.testing.io, rendered, .{});
        return .{
            .dir = dir,
            .parent = parent,
            .name = name,
            .name_len = rendered.len,
        };
    }

    fn cleanup(self: *OutsideGitTmp) void {
        self.dir.close(std.testing.io);
        self.parent.deleteTree(std.testing.io, self.name[0..self.name_len]) catch {};
        self.parent.close(std.testing.io);
        self.* = undefined;
    }
};

test "ADE Git roots discover normal and linked worktree markers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "normal/.git");
    try tmp.dir.createDirPath(std.testing.io, "normal/nested");
    try tmp.dir.createDirPath(std.testing.io, "linked/nested");
    try tmp.dir.createDirPath(std.testing.io, "linked-absolute/nested");
    try tmp.dir.createDirPath(std.testing.io, "metadata/worktrees/linked");
    try tmp.dir.createDirPath(std.testing.io, "metadata/worktrees/linked-absolute");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "linked/.git",
        .data = "gitdir: ../metadata/worktrees/linked\n",
    });
    const absolute_gitdir = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "metadata/worktrees/linked-absolute",
    );
    defer alloc.free(absolute_gitdir);
    const absolute_marker = try std.fmt.allocPrint(alloc, "gitdir: {s}\n", .{absolute_gitdir});
    defer alloc.free(absolute_marker);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "linked-absolute/.git",
        .data = absolute_marker,
    });

    const normal_nested = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "normal/nested");
    defer alloc.free(normal_nested);
    const normal_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "normal");
    defer alloc.free(normal_root);
    const linked_nested = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "linked/nested");
    defer alloc.free(linked_nested);
    const linked_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "linked");
    defer alloc.free(linked_root);
    const linked_absolute_nested = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "linked-absolute/nested",
    );
    defer alloc.free(linked_absolute_nested);
    const linked_absolute_root = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "linked-absolute",
    );
    defer alloc.free(linked_absolute_root);

    const discovered_normal = (try discoverGitRoot(alloc, normal_nested, .directory)).?;
    defer alloc.free(discovered_normal);
    try std.testing.expectEqualStrings(normal_root, discovered_normal);
    const discovered_linked = (try discoverGitRoot(alloc, linked_nested, .directory)).?;
    defer alloc.free(discovered_linked);
    try std.testing.expectEqualStrings(linked_root, discovered_linked);
    const discovered_linked_absolute = (try discoverGitRoot(
        alloc,
        linked_absolute_nested,
        .directory,
    )).?;
    defer alloc.free(discovered_linked_absolute);
    try std.testing.expectEqualStrings(linked_absolute_root, discovered_linked_absolute);
}

test "ADE Git roots reject regular markers without a valid Git directory pointer" {
    const alloc = std.testing.allocator;
    var tmp = try OutsideGitTmp.init();
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "invalid/nested");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "invalid/.git",
        .data = "ordinary file\n",
    });
    try tmp.dir.createDirPath(std.testing.io, "target-file/nested");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "not-a-directory",
        .data = "not a directory",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "target-file/.git",
        .data = "gitdir: ../not-a-directory\n",
    });

    const invalid = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "invalid/nested");
    defer alloc.free(invalid);
    const target_file = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target-file/nested");
    defer alloc.free(target_file);
    try std.testing.expect((try discoverGitRoot(alloc, invalid, .directory)) == null);
    try std.testing.expect((try discoverGitRoot(alloc, target_file, .directory)) == null);
}

test "ADE Git root checkpoint atomically replaces stale content with private schema one state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const checkpoint_path = try std.fs.path.join(alloc, &.{ tmp_root, "checkpoint.json" });
    defer alloc.free(checkpoint_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "checkpoint.json",
        .data = "malformed stale checkpoint",
    });

    try replacePrivateFileAtomic(
        alloc,
        checkpoint_path,
        "{\"schema\":1,\"instance_id\":\"instance-test\",\"revision\":1,\"git_roots\":[\"/tmp/repo\"]}\n",
        1,
    );
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, checkpoint_path, .{});
    defer file.close(std.testing.io);
    const bytes = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "{\"schema\":1"));
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "ADE Git roots retain first discovery order and checkpoint without a socket" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo-a/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo-a/nested");
    try tmp.dir.createDirPath(std.testing.io, "repo-b/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo-b/nested");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo-b/nested/edited.txt",
        .data = "edited",
    });

    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const repo_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo-a");
    defer alloc.free(repo_a);
    const repo_a_nested = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo-a/nested");
    defer alloc.free(repo_a_nested);
    const repo_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo-b");
    defer alloc.free(repo_b);
    const repo_b_nested = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo-b/nested");
    defer alloc.free(repo_b_nested);
    const edited_path = try std.fs.path.join(alloc, &.{ repo_b_nested, "edited.txt" });
    defer alloc.free(edited_path);
    const checkpoint_path = try std.fs.path.join(alloc, &.{ tmp_root, "checkpoint.json" });
    defer alloc.free(checkpoint_path);

    const Recorder = struct {
        alloc: std.mem.Allocator,
        roots: [4]?[]u8 = @splat(null),
        revisions: [4]u64 = @splat(0),
        reasons: [4]DiscoveryReason = undefined,
        scopes: [4]hooks.ScopeKind = undefined,
        parent_session_ids: [4]?[]u8 = @splat(null),
        count: usize = 0,

        fn report(raw: *anyopaque, discovery: Discovery) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.roots[self.count] = self.alloc.dupe(u8, discovery.root) catch return;
            self.revisions[self.count] = discovery.revision;
            self.reasons[self.count] = discovery.reason;
            self.scopes[self.count] = discovery.scope.kind;
            self.parent_session_ids[self.count] = if (discovery.parent_session_id) |parent_id|
                self.alloc.dupe(u8, parent_id) catch return
            else
                null;
            self.count += 1;
        }

        fn deinit(self: *@This()) void {
            for (self.roots) |maybe_root| {
                if (maybe_root) |root| self.alloc.free(root);
            }
            for (self.parent_session_ids) |maybe_parent| {
                if (maybe_parent) |parent_id| self.alloc.free(parent_id);
            }
        }
    };

    var recorder = Recorder{ .alloc = alloc };
    defer recorder.deinit();
    var tracker: Tracker = .{};
    try tracker.init(
        alloc,
        "instance-order",
        checkpoint_path,
        .{ .context = &recorder, .report_fn = Recorder.report },
        .{
            .kind = .interactive,
            .workspace_root = repo_a_nested,
            .session_id = "main-session",
        },
    );
    tracker.reportEditedPaths(.{
        .scope = .{
            .kind = .interactive,
            .workspace_root = repo_a_nested,
            .session_id = "main-session",
        },
        .source = .terminal_write,
        .paths = &.{repo_a_nested},
    });
    tracker.reportEditedPaths(.{
        .scope = .{
            .kind = .subagent,
            .workspace_root = repo_a_nested,
            .session_id = "child-session",
            .subagent_id = 7,
        },
        .parent_session_id = "captured-parent-session",
        .source = .file_mutation,
        .paths = &.{edited_path},
    });
    tracker.reportEditedPaths(.{
        .scope = .{
            .kind = .interactive,
            .workspace_root = repo_a_nested,
            .session_id = "main-session",
        },
        .source = .terminal_write,
        .paths = &.{repo_b_nested},
    });
    tracker.waitUntilIdle();
    tracker.deinit();

    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    try std.testing.expectEqualStrings(repo_a, recorder.roots[0].?);
    try std.testing.expectEqualStrings(repo_b, recorder.roots[1].?);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, recorder.revisions[0..2]);
    try std.testing.expectEqualSlices(
        DiscoveryReason,
        &.{ .launch_directory, .subagent_file_mutation },
        recorder.reasons[0..2],
    );
    try std.testing.expectEqualSlices(
        hooks.ScopeKind,
        &.{ .interactive, .subagent },
        recorder.scopes[0..2],
    );
    try std.testing.expect(recorder.parent_session_ids[0] == null);
    try std.testing.expectEqualStrings(
        "captured-parent-session",
        recorder.parent_session_ids[1].?,
    );

    var checkpoint_file = try std.Io.Dir.openFileAbsolute(std.testing.io, checkpoint_path, .{});
    defer checkpoint_file.close(std.testing.io);
    const bytes = try io_mod.readFileToEnd(alloc, &checkpoint_file, 4096);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema").?.integer);
    try std.testing.expectEqualStrings(
        "instance-order",
        parsed.value.object.get("instance_id").?.string,
    );
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("revision").?.integer);
    const roots = parsed.value.object.get("git_roots").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqualStrings(repo_a, roots[0].string);
    try std.testing.expectEqualStrings(repo_b, roots[1].string);
}

test "ADE Git roots replace stale output with an empty non-Git launch checkpoint" {
    const alloc = std.testing.allocator;
    var tmp = try OutsideGitTmp.init();
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "plain/nested");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "checkpoint.json",
        .data = "{\"schema\":1,\"instance_id\":\"wrong\",\"revision\":99,\"git_roots\":[\"/stale\"]}\n",
    });

    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const plain = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "plain/nested");
    defer alloc.free(plain);
    const checkpoint_path = try std.fs.path.join(alloc, &.{ tmp_root, "checkpoint.json" });
    defer alloc.free(checkpoint_path);

    var tracker: Tracker = .{};
    try tracker.init(
        alloc,
        "instance-empty",
        checkpoint_path,
        null,
        .{ .kind = .interactive, .workspace_root = plain },
    );
    tracker.waitUntilIdle();
    tracker.deinit();

    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, checkpoint_path, .{});
    defer file.close(std.testing.io);
    const bytes = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "instance-empty",
        parsed.value.object.get("instance_id").?.string,
    );
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("revision").?.integer);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("git_roots").?.array.items.len);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "ADE Git roots ignore an unwritable checkpoint target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not-a-directory", .data = "x" });

    const repo = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(repo);
    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const checkpoint_path = try std.fs.path.join(
        alloc,
        &.{ tmp_root, "not-a-directory", "checkpoint.json" },
    );
    defer alloc.free(checkpoint_path);

    var tracker: Tracker = .{};
    try tracker.init(
        alloc,
        "instance-unwritable",
        checkpoint_path,
        null,
        .{ .kind = .interactive, .workspace_root = repo },
    );
    tracker.waitUntilIdle();
    tracker.deinit();
}

test "ADE Git roots cap queued observations and discard backlog on shutdown" {
    const alloc = std.testing.allocator;
    var tracker = Tracker{
        .enabled = true,
        .alloc = alloc,
    };
    const scope = hooks.Scope{
        .kind = .subagent,
        .workspace_root = "/tmp/workspace",
        .session_id = "child-session",
    };
    for (0..max_queued_observations + 16) |_| {
        tracker.enqueueBatch(
            scope,
            "parent-session",
            .subagent_terminal_write,
            .directory,
            &.{"/tmp/workspace"},
        );
    }
    try std.testing.expectEqual(max_queued_observations, tracker.queue_len);
    try std.testing.expect(tracker.queued_bytes <= max_queued_observation_bytes);

    tracker.clearQueue();
    const oversized = try alloc.alloc(u8, max_queued_observation_bytes);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    tracker.enqueueBatch(
        scope,
        "parent-session",
        .subagent_terminal_write,
        .directory,
        &.{oversized},
    );
    try std.testing.expectEqual(@as(usize, 0), tracker.queue_len);
    try std.testing.expectEqual(@as(usize, 0), tracker.queued_bytes);

    tracker.enqueueBatch(
        scope,
        "parent-session",
        .subagent_terminal_write,
        .directory,
        &.{"/tmp/workspace"},
    );
    try std.testing.expectEqual(@as(usize, 1), tracker.queue_len);
    tracker.deinit();
    try std.testing.expect(!tracker.enabled);
}
