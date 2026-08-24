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

    fn deinit(self: QueuedObservation, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(@constCast(self.scope.workspace_root));
        if (self.scope.session_id) |session_id| alloc.free(@constCast(session_id));
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
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.wake.broadcast(io);
        self.mutex.unlock(io);
        if (self.worker_thread) |thread| thread.join();

        self.clearQueue();
        const alloc = self.alloc orelse {
            self.* = .{};
            return;
        };
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
        self.enqueueBatch(observation.scope, reason, switch (observation.source) {
            .file_mutation => .file,
            .terminal_write => .directory,
        }, observation.paths);
    }

    fn enqueueBatch(
        self: *Tracker,
        scope: hooks.Scope,
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
            const queued = alloc.create(QueuedObservation) catch {
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
            };
            self.queue.append(&queued.node);
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
            const observation = self.takeLocked();
            const should_stop = self.stopping and observation == null;
            self.mutex.unlock(io);
            if (should_stop) return;
            if (observation) |queued| {
                defer {
                    queued.deinit(alloc);
                    alloc.destroy(queued);
                }
                const maybe_root = discoverGitRoot(alloc, queued.path, queued.kind) catch |err| {
                    debug_trace.logf("ade_git_roots", "discovery failed err={s}", .{@errorName(err)});
                    if (queued.reason == .launch_directory) self.replaceInitialEmptyCheckpoint();
                    continue;
                };
                const root = maybe_root orelse {
                    if (queued.reason == .launch_directory) self.replaceInitialEmptyCheckpoint();
                    continue;
                };
                if (self.containsRoot(root)) {
                    alloc.free(root);
                    continue;
                }
                self.roots.append(alloc, root) catch {
                    alloc.free(root);
                    continue;
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
                });
            }
        }
    }

    fn takeLocked(self: *Tracker) ?*QueuedObservation {
        const node = self.queue.popFirst() orelse return null;
        return @fieldParentPtr("node", node);
    }

    fn clearQueue(self: *Tracker) void {
        const alloc = self.alloc orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.takeLocked()) |observation| {
            observation.deinit(alloc);
            alloc.destroy(observation);
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
            if (stat.kind == .directory or stat.kind == .file) return current;
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
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "linked/.git",
        .data = "gitdir: /tmp/example.git/worktrees/linked\n",
    });

    const normal_nested = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "normal/nested");
    defer alloc.free(normal_nested);
    const normal_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "normal");
    defer alloc.free(normal_root);
    const linked_nested = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "linked/nested");
    defer alloc.free(linked_nested);
    const linked_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "linked");
    defer alloc.free(linked_root);

    const discovered_normal = (try discoverGitRoot(alloc, normal_nested, .directory)).?;
    defer alloc.free(discovered_normal);
    try std.testing.expectEqualStrings(normal_root, discovered_normal);
    const discovered_linked = (try discoverGitRoot(alloc, linked_nested, .directory)).?;
    defer alloc.free(discovered_linked);
    try std.testing.expectEqualStrings(linked_root, discovered_linked);
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
        count: usize = 0,

        fn report(raw: *anyopaque, discovery: Discovery) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.roots[self.count] = self.alloc.dupe(u8, discovery.root) catch return;
            self.revisions[self.count] = discovery.revision;
            self.reasons[self.count] = discovery.reason;
            self.scopes[self.count] = discovery.scope.kind;
            self.count += 1;
        }

        fn deinit(self: *@This()) void {
            for (self.roots) |maybe_root| {
                if (maybe_root) |root| self.alloc.free(root);
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
    tracker.deinit();
}
