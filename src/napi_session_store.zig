const std = @import("std");
const js_host_auth = @import("core/auth/js_host_auth.zig");
const io_mod = @import("core/shared/io.zig");
const secret = @import("core/auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const Handle = u32;

pub const Kind = enum {
    load,
    commit,
};

pub const Status = enum(u8) {
    success = 0,
    missing = 1,
    conflict = 2,
    failure = 3,
};

pub const FinishResult = enum(u8) {
    stale = 0,
    applied = 1,
};

pub const Request = struct {
    handle: Handle,
    kind: Kind,
    bytes: []u8,
    expected_revision: ?[]u8,

    pub fn deinit(self: *Request, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.bytes);
        if (self.expected_revision) |revision| alloc.free(revision);
        self.* = undefined;
    }
};

const Phase = enum {
    idle,
    pending,
    taken,
    complete,
    shutdown,
};

const Exchange = struct {
    status: Status,
    bytes: []u8,
    revision: []u8,

    fn deinit(self: *Exchange, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.bytes);
        alloc.free(self.revision);
        self.* = undefined;
    }
};

pub const Bridge = struct {
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    phase: Phase = .idle,
    next_handle: Handle = 1,
    handle: Handle = 0,
    kind: Kind = .load,
    request_bytes: std.ArrayList(u8) = .empty,
    expected_revision: std.ArrayList(u8) = .empty,
    has_expected_revision: bool = false,
    response_status: Status = .failure,
    response_bytes: std.ArrayList(u8) = .empty,
    response_revision: std.ArrayList(u8) = .empty,

    pub fn provider(self: *Bridge) js_host_auth.SessionStore {
        return .{
            .context = self,
            .load_fn = load,
            .commit_fn = commit,
            .remove_fn = remove,
        };
    }

    fn load(raw: ?*anyopaque, alloc: Allocator) !?js_host_auth.StoredSession {
        const self: *Bridge = @ptrCast(@alignCast(raw.?));
        var result = try self.exchange(alloc, .load, &.{}, null);
        defer result.deinit(alloc);
        return switch (result.status) {
            .success => loaded: {
                const bytes = result.bytes;
                result.bytes = &.{};
                const revision = result.revision;
                result.revision = &.{};
                break :loaded .{ .bytes = bytes, .revision = revision };
            },
            .missing => null,
            .conflict => error.OAuthSessionRevisionConflict,
            .failure => error.OAuthSessionStoreUnavailable,
        };
    }

    fn commit(
        raw: ?*anyopaque,
        alloc: Allocator,
        bytes: []const u8,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        const self: *Bridge = @ptrCast(@alignCast(raw.?));
        var result = try self.exchange(alloc, .commit, bytes, expected_revision);
        defer result.deinit(alloc);
        return switch (result.status) {
            .success => committed: {
                const revision = result.revision;
                result.revision = &.{};
                break :committed revision;
            },
            .conflict => error.OAuthSessionRevisionConflict,
            .missing, .failure => error.OAuthSessionStoreUnavailable,
        };
    }

    fn remove(_: ?*anyopaque, _: ?[]const u8) !js_host_auth.RemoveOutcome {
        return error.OAuthSessionStoreUnavailable;
    }

    fn exchange(
        self: *Bridge,
        alloc: Allocator,
        kind: Kind,
        bytes: []const u8,
        expected_revision: ?[]const u8,
    ) !Exchange {
        if (bytes.len > js_host_auth.max_session_bytes) return error.OAuthSessionTooLarge;
        if (expected_revision) |revision| {
            if (revision.len > js_host_auth.max_revision_bytes) return error.OAuthSessionRevisionTooLarge;
        }

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.phase != .idle and self.phase != .shutdown) {
            self.wake.waitUncancelable(io, &self.mutex);
        }
        if (self.phase == .shutdown) return error.OAuthSessionStoreUnavailable;

        self.clearRequest();
        self.clearResponse();
        try self.request_bytes.appendSlice(std.heap.c_allocator, bytes);
        errdefer self.clearRequest();
        if (expected_revision) |revision| {
            try self.expected_revision.appendSlice(std.heap.c_allocator, revision);
        }
        self.has_expected_revision = expected_revision != null;
        const handle = self.next_handle;
        self.next_handle +%= 1;
        if (self.next_handle == 0) self.next_handle = 1;
        self.handle = handle;
        self.kind = kind;
        self.phase = .pending;
        self.wake.broadcast(io);

        while (self.phase != .complete and self.phase != .shutdown) {
            self.wake.waitUncancelable(io, &self.mutex);
        }
        if (self.phase == .shutdown) return error.OAuthSessionStoreUnavailable;

        errdefer self.releaseExchange(io);
        const response_bytes = try alloc.dupe(u8, self.response_bytes.items);
        errdefer secret.zeroAndFree(alloc, response_bytes);
        const response_revision = try alloc.dupe(u8, self.response_revision.items);
        const status = self.response_status;
        self.releaseExchange(io);
        return .{
            .status = status,
            .bytes = response_bytes,
            .revision = response_revision,
        };
    }

    pub fn takeRequest(self: *Bridge, alloc: Allocator) !?Request {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.phase != .pending) return null;

        const bytes = try alloc.dupe(u8, self.request_bytes.items);
        errdefer secret.zeroAndFree(alloc, bytes);
        const expected = if (self.has_expected_revision)
            try alloc.dupe(u8, self.expected_revision.items)
        else
            null;
        errdefer if (expected) |revision| alloc.free(revision);
        const request = Request{
            .handle = self.handle,
            .kind = self.kind,
            .bytes = bytes,
            .expected_revision = expected,
        };
        self.phase = .taken;
        return request;
    }

    pub fn finish(
        self: *Bridge,
        handle: Handle,
        status: Status,
        bytes: []const u8,
        revision: []const u8,
    ) !FinishResult {
        if (bytes.len > js_host_auth.max_session_bytes or revision.len > js_host_auth.max_revision_bytes) {
            return error.OAuthSessionTooLarge;
        }
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.phase != .taken or handle != self.handle) return .stale;

        self.clearResponse();
        try self.response_bytes.appendSlice(std.heap.c_allocator, bytes);
        errdefer self.clearResponse();
        try self.response_revision.appendSlice(std.heap.c_allocator, revision);
        self.response_status = status;
        self.phase = .complete;
        self.wake.broadcast(io);
        return .applied;
    }

    pub fn abortCurrent(self: *Bridge) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.phase != .pending and self.phase != .taken) return;
        self.clearResponse();
        self.response_status = .failure;
        self.phase = .complete;
        self.wake.broadcast(io);
    }

    pub fn shutdown(self: *Bridge) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.phase = .shutdown;
        self.clearRequest();
        self.clearResponse();
        self.wake.broadcast(io);
    }

    pub fn deinit(self: *Bridge) void {
        self.clearRequest();
        self.clearResponse();
        self.request_bytes.deinit(std.heap.c_allocator);
        self.expected_revision.deinit(std.heap.c_allocator);
        self.response_bytes.deinit(std.heap.c_allocator);
        self.response_revision.deinit(std.heap.c_allocator);
        self.* = undefined;
    }

    fn clearRequest(self: *Bridge) void {
        @memset(self.request_bytes.items, 0);
        self.request_bytes.clearRetainingCapacity();
        @memset(self.expected_revision.items, 0);
        self.expected_revision.clearRetainingCapacity();
        self.has_expected_revision = false;
    }

    fn clearResponse(self: *Bridge) void {
        @memset(self.response_bytes.items, 0);
        self.response_bytes.clearRetainingCapacity();
        @memset(self.response_revision.items, 0);
        self.response_revision.clearRetainingCapacity();
        self.response_status = .failure;
    }

    fn releaseExchange(self: *Bridge, io: std.Io) void {
        self.clearRequest();
        self.clearResponse();
        self.handle = 0;
        self.phase = .idle;
        self.wake.broadcast(io);
    }
};

test "N-API Codex session bridge exchanges requests and keeps stale operations inert" {
    var bridge = Bridge{};
    defer bridge.deinit();

    try std.testing.expect((try bridge.takeRequest(std.testing.allocator)) == null);
    try std.testing.expectEqual(
        FinishResult.stale,
        try bridge.finish(7, .failure, &.{}, &.{}),
    );

    const LoadWorker = struct {
        bridge: *Bridge,
        stored: ?js_host_auth.StoredSession = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.stored = self.bridge.provider().load(std.heap.c_allocator) catch |err| {
                self.err = err;
                return;
            };
        }
    };
    var load_worker = LoadWorker{ .bridge = &bridge };
    const load_thread = try std.Thread.spawn(.{}, LoadWorker.run, .{&load_worker});
    var load_joined = false;
    defer if (!load_joined) {
        bridge.shutdown();
        load_thread.join();
    };
    var load_request: ?Request = null;
    while (load_request == null) {
        load_request = try bridge.takeRequest(std.heap.c_allocator);
        if (load_request == null) std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    defer load_request.?.deinit(std.heap.c_allocator);
    try std.testing.expectEqual(Kind.load, load_request.?.kind);
    try std.testing.expectEqual(
        FinishResult.applied,
        try bridge.finish(load_request.?.handle, .success, "session-bytes", "revision-1"),
    );
    load_thread.join();
    load_joined = true;
    try std.testing.expect(load_worker.err == null);
    var stored = load_worker.stored orelse return error.MissingTestSession;
    defer stored.deinit(std.heap.c_allocator);
    try std.testing.expectEqualStrings("session-bytes", stored.bytes);
    try std.testing.expectEqualStrings("revision-1", stored.revision);

    const CommitWorker = struct {
        bridge: *Bridge,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            const revision = self.bridge.provider().commit(
                std.heap.c_allocator,
                "replacement-session",
                "revision-1",
            ) catch |err| {
                self.err = err;
                return;
            };
            std.heap.c_allocator.free(revision);
        }
    };
    var commit_worker = CommitWorker{ .bridge = &bridge };
    const commit_thread = try std.Thread.spawn(.{}, CommitWorker.run, .{&commit_worker});
    var commit_joined = false;
    defer if (!commit_joined) {
        bridge.shutdown();
        commit_thread.join();
    };
    var commit_request: ?Request = null;
    while (commit_request == null) {
        commit_request = try bridge.takeRequest(std.heap.c_allocator);
        if (commit_request == null) std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    defer commit_request.?.deinit(std.heap.c_allocator);
    try std.testing.expectEqual(Kind.commit, commit_request.?.kind);
    try std.testing.expectEqualStrings("replacement-session", commit_request.?.bytes);
    try std.testing.expectEqualStrings("revision-1", commit_request.?.expected_revision.?);
    try std.testing.expectEqual(
        FinishResult.applied,
        try bridge.finish(commit_request.?.handle, .conflict, &.{}, &.{}),
    );
    commit_thread.join();
    commit_joined = true;
    try std.testing.expectEqual(error.OAuthSessionRevisionConflict, commit_worker.err.?);
}
