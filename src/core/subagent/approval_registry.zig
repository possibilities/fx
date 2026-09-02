const std = @import("std");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;
const max_pending: usize = 64;

pub const Error = error{
    OutOfMemory,
    CapacityExceeded,
    CommitFailed,
    RegistryClosed,
    RequestConflict,
    RequestNotFound,
    StaleRequest,
    WrongChild,
};

pub const ResolveResult = enum { accepted, rejected };

/// A copied, stable identity for one child's outstanding attention. The ADE
/// feed attributes a resolution to the child rather than to the surface the
/// human answered on, so the identity must survive the binding it came from.
pub const AttentionToken = [32]u8;

pub fn attentionToken(child_id: []const u8, request_id: []const u8) AttentionToken {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(child_id);
    hash.update(&.{0});
    hash.update(request_id);
    var digest: AttentionToken = undefined;
    hash.final(&digest);
    return digest;
}

/// Notified when an outstanding attention identity is abandoned rather than
/// answered, so a consumer never waits forever on a resolution that can no
/// longer arrive.
pub const AttentionInvalidationObserver = struct {
    context: ?*anyopaque = null,
    observe_fn: *const fn (?*anyopaque, []const u8, AttentionToken) void,

    fn observe(
        self: AttentionInvalidationObserver,
        child_id: []const u8,
        token: AttentionToken,
    ) void {
        self.observe_fn(self.context, child_id, token);
    }
};

pub const ObservedResolveResult = struct {
    result: ResolveResult,
    observer_ran: bool = false,
};

pub const max_pending_child_snapshot: usize = 32;
pub const max_pending_child_id_bytes: usize = 64;

/// Every distinct child currently blocked on a permission, with the attention
/// identity each one owns. The consumer announces every blocked child, not
/// only the one the main prompt happens to mirror.
pub const PendingChildren = struct {
    storage: [max_pending_child_snapshot][max_pending_child_id_bytes]u8 = undefined,
    lengths: [max_pending_child_snapshot]usize = @splat(0),
    attention_tokens: [max_pending_child_snapshot]AttentionToken = undefined,
    len: usize = 0,
    truncated: bool = false,

    pub fn at(self: *const PendingChildren, index: usize) []const u8 {
        return self.storage[index][0..self.lengths[index]];
    }

    pub fn attentionTokenAt(self: *const PendingChildren, index: usize) AttentionToken {
        return self.attention_tokens[index];
    }

    fn contains(self: *const PendingChildren, child_id: []const u8) bool {
        for (0..self.len) |index| {
            if (std.mem.eql(u8, self.at(index), child_id)) return true;
        }
        return false;
    }
};

pub const WorkerRoute = struct {
    context: *anyopaque,
    submit_fn: *const fn (
        *anyopaque,
        u64,
        permission_request.OwnedPermissionResponse,
        ?worker_runtime.WorkerRuntime.PermissionCommit,
    ) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult,
    cancel_fn: *const fn (*anyopaque) void,
    pin_fn: *const fn (*anyopaque) bool,
    release_fn: *const fn (*anyopaque) void,
    /// Runs a lifecycle observer at the worker's release point, without the
    /// worker mutex. Absent for routes that cannot observe; those fall back to
    /// the plain submit and report `observer_ran = false`.
    submit_observed_fn: ?*const fn (
        *anyopaque,
        u64,
        permission_request.OwnedPermissionResponse,
        ?worker_runtime.WorkerRuntime.PermissionCommit,
        ?worker_runtime.DecisionObserver,
    ) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult = null,

    fn eql(self: WorkerRoute, other: WorkerRoute) bool {
        return self.context == other.context and
            self.submit_fn == other.submit_fn and
            self.submit_observed_fn == other.submit_observed_fn and
            self.cancel_fn == other.cancel_fn and
            self.pin_fn == other.pin_fn and
            self.release_fn == other.release_fn;
    }

    fn submit(
        self: WorkerRoute,
        request_id: u64,
        response: permission_request.OwnedPermissionResponse,
        commit: ?worker_runtime.WorkerRuntime.PermissionCommit,
    ) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult {
        return self.submit_fn(self.context, request_id, response, commit);
    }

    fn submitObserved(
        self: WorkerRoute,
        request_id: u64,
        response: permission_request.OwnedPermissionResponse,
        commit: ?worker_runtime.WorkerRuntime.PermissionCommit,
        observer: ?worker_runtime.DecisionObserver,
    ) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult {
        if (self.submit_observed_fn) |observed| {
            return observed(self.context, request_id, response, commit, observer);
        }
        return self.submit_fn(self.context, request_id, response, commit);
    }

    fn cancel(self: WorkerRoute) void {
        self.cancel_fn(self.context);
    }

    fn pin(self: WorkerRoute) bool {
        return self.pin_fn(self.context);
    }

    fn release(self: WorkerRoute) void {
        self.release_fn(self.context);
    }
};

const Binding = struct {
    request_id: []u8,
    child_id: []u8,
    root_id: []u8,
    work_id: []u8,
    request: permission_request.OwnedPermissionRequest,
    worker: WorkerRoute,
    worker_request_id: u64,

    fn deinit(self: *Binding, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        alloc.free(self.root_id);
        alloc.free(self.work_id);
        self.request.deinit(alloc);
        self.* = undefined;
    }
};

pub const PendingRequest = struct {
    request_id: []u8,
    child_id: []u8,
    request: permission_request.OwnedPermissionRequest,

    pub fn deinit(self: *PendingRequest, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        self.request.deinit(alloc);
        self.* = undefined;
    }
};

pub const Registry = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    bindings: std.ArrayList(Binding) = .empty,
    pending_revision: u64 = 0,
    closed: bool = false,
    worker_routes_closed: bool = false,
    attention_invalidation_observer: ?AttentionInvalidationObserver = null,

    pub fn setAttentionInvalidationObserver(
        self: *Registry,
        observer: AttentionInvalidationObserver,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        std.debug.assert(self.bindings.items.len == 0);
        self.attention_invalidation_observer = observer;
    }

    pub fn pendingRevision(self: *Registry) u64 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.pending_revision;
    }

    pub fn firstPendingRequest(
        self: *Registry,
        alloc: Allocator,
        root_id: []const u8,
    ) Error!?PendingRequest {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.RegistryClosed;
        for (self.bindings.items) |*binding| {
            if (!std.mem.eql(u8, binding.root_id, root_id)) continue;
            const request_id = try alloc.dupe(u8, binding.request_id);
            errdefer alloc.free(request_id);
            const child_id = try alloc.dupe(u8, binding.child_id);
            errdefer alloc.free(child_id);
            const request = permission_request.OwnedPermissionRequest.dupe(
                alloc,
                binding.request.view(),
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.CommitFailed,
            };
            return .{
                .request_id = request_id,
                .child_id = child_id,
                .request = request,
            };
        }
        return null;
    }

    pub fn registerTool(
        self: *Registry,
        stable_request_id: []const u8,
        child_id: []const u8,
        root_id: []const u8,
        work_id: []const u8,
        request: permission_request.PermissionRequest,
        _: []const types.PermissionGrant,
        worker: WorkerRoute,
        _: i64,
    ) Error!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.RegistryClosed;
        if (self.find(stable_request_id)) |index| {
            const existing = self.bindings.items[index];
            if (!std.mem.eql(u8, existing.child_id, child_id) or
                !std.mem.eql(u8, existing.work_id, work_id) or
                !existing.worker.eql(worker) or
                existing.worker_request_id != request.id)
            {
                return error.RequestConflict;
            }
            return;
        }
        if (self.bindings.items.len >= max_pending) return error.CapacityExceeded;
        var projected = request;
        projected.origin = .{ .subagent = child_id };
        const owned_request = permission_request.OwnedPermissionRequest.dupe(
            self.alloc,
            projected,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CommitFailed,
        };
        errdefer {
            var value = owned_request;
            value.deinit(self.alloc);
        }
        const owned_request_id = try self.alloc.dupe(u8, stable_request_id);
        errdefer self.alloc.free(owned_request_id);
        const owned_child_id = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_child_id);
        const owned_root_id = try self.alloc.dupe(u8, root_id);
        errdefer self.alloc.free(owned_root_id);
        const owned_work_id = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(owned_work_id);
        try self.bindings.append(self.alloc, .{
            .request_id = owned_request_id,
            .child_id = owned_child_id,
            .root_id = owned_root_id,
            .work_id = owned_work_id,
            .request = owned_request,
            .worker = worker,
            .worker_request_id = request.id,
        });
        self.pending_revision +|= 1;
    }

    pub fn resolve(
        self: *Registry,
        request_id: []const u8,
        child_id: []const u8,
        decision: types.ToolPermissionDecision,
        feedback: ?[]const u8,
        timestamp_ms: i64,
    ) Error!ResolveResult {
        return (try self.resolveObserved(
            request_id,
            child_id,
            decision,
            feedback,
            timestamp_ms,
            null,
        )).result;
    }

    /// Answers one child's outstanding permission and runs `observer` at the
    /// worker's release point, so the child's own resolution is published
    /// before the worker can resume. The registry pins the route across the
    /// observation, so the worker cannot be freed while the observer runs.
    pub fn resolveObserved(
        self: *Registry,
        request_id: []const u8,
        child_id: []const u8,
        decision: types.ToolPermissionDecision,
        feedback: ?[]const u8,
        _: i64,
        observer: ?worker_runtime.DecisionObserver,
    ) Error!ObservedResolveResult {
        const owned_feedback = if (feedback) |value|
            try self.alloc.dupe(u8, value)
        else
            null;
        var feedback_owned = owned_feedback != null;
        errdefer if (feedback_owned) self.alloc.free(owned_feedback.?);

        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.closed) {
            self.mutex.unlock(io_mod.getIo());
            return error.RegistryClosed;
        }
        if (self.worker_routes_closed) {
            self.mutex.unlock(io_mod.getIo());
            return error.StaleRequest;
        }
        const index = self.find(request_id) orelse {
            self.mutex.unlock(io_mod.getIo());
            return error.RequestNotFound;
        };
        const binding = &self.bindings.items[index];
        if (!std.mem.eql(u8, binding.child_id, child_id)) {
            self.mutex.unlock(io_mod.getIo());
            return error.WrongChild;
        }
        if (!binding.worker.pin()) {
            var removed = self.bindings.orderedRemove(index);
            self.pending_revision +|= 1;
            self.mutex.unlock(io_mod.getIo());
            defer removed.deinit(self.alloc);
            if (feedback_owned) {
                self.alloc.free(owned_feedback.?);
                feedback_owned = false;
            }
            return .{ .result = .rejected };
        }
        var removed = self.bindings.orderedRemove(index);
        self.pending_revision +|= 1;
        self.mutex.unlock(io_mod.getIo());
        defer removed.deinit(self.alloc);
        defer removed.worker.release();

        const observable = observer != null and removed.worker.submit_observed_fn != null;
        const submission = removed.worker.submitObserved(
            removed.worker_request_id,
            permission_request.OwnedPermissionResponse.init(
                self.alloc,
                decision,
                owned_feedback,
            ),
            .{ .context = self, .commit_fn = commitNoop },
            observer,
        ) catch |err| {
            feedback_owned = false;
            removed.worker.cancel();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PermissionCapacityExceeded => error.CapacityExceeded,
                error.PermissionCommitFailed => error.CommitFailed,
            };
        };
        feedback_owned = false;
        if (submission != .accepted) return .{ .result = .rejected };
        return .{ .result = .accepted, .observer_ran = observable };
    }

    /// Closes every outstanding attention identity this child still owns,
    /// without answering it. Durable cancellation calls this before any worker
    /// or waiter can publish a late edge from the abandoned approval.
    pub fn closeChildAttention(self: *Registry, child_id: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.bindings.items) |binding| {
            if (!std.mem.eql(u8, binding.child_id, child_id)) continue;
            self.observeAttentionInvalidatedLocked(binding);
        }
    }

    /// Retires every worker route before shutdown signals let workers publish
    /// terminal lifecycle edges, and refuses later resolution as stale.
    pub fn detachWorkerRoutes(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.worker_routes_closed = true;
        var index = self.bindings.items.len;
        while (index > 0) {
            index -= 1;
            self.observeAttentionInvalidatedLocked(self.bindings.items[index]);
            var removed = self.bindings.orderedRemove(index);
            removed.worker.cancel();
            removed.deinit(self.alloc);
            self.pending_revision +|= 1;
        }
    }

    fn observeAttentionInvalidatedLocked(self: *Registry, binding: Binding) void {
        const observer = self.attention_invalidation_observer orelse return;
        observer.observe(
            binding.child_id,
            attentionToken(binding.child_id, binding.request_id),
        );
    }

    pub fn snapshotPendingChildren(self: *Registry, out: *PendingChildren) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        out.len = 0;
        out.truncated = false;
        // A closed registry or a retired route has no waiter left to unblock.
        if (self.closed or self.worker_routes_closed) return;
        for (self.bindings.items) |binding| {
            if (binding.child_id.len > max_pending_child_id_bytes) {
                out.truncated = true;
                continue;
            }
            if (out.contains(binding.child_id)) continue;
            if (out.len == max_pending_child_snapshot) {
                out.truncated = true;
                break;
            }
            @memcpy(out.storage[out.len][0..binding.child_id.len], binding.child_id);
            out.lengths[out.len] = binding.child_id.len;
            out.attention_tokens[out.len] = attentionToken(binding.child_id, binding.request_id);
            out.len += 1;
        }
    }

    pub fn invalidateChild(
        self: *Registry,
        child_id: []const u8,
    ) Error!usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var changed: usize = 0;
        var index = self.bindings.items.len;
        while (index > 0) {
            index -= 1;
            if (!std.mem.eql(u8, self.bindings.items[index].child_id, child_id)) continue;
            self.observeAttentionInvalidatedLocked(self.bindings.items[index]);
            var removed = self.bindings.orderedRemove(index);
            removed.worker.cancel();
            removed.deinit(self.alloc);
            changed += 1;
        }
        if (changed > 0) self.pending_revision +|= 1;
        return changed;
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.closed = true;
        for (self.bindings.items) |*binding| {
            self.observeAttentionInvalidatedLocked(binding.*);
            binding.worker.cancel();
            binding.deinit(self.alloc);
        }
        self.bindings.deinit(self.alloc);
        self.mutex.unlock(io_mod.getIo());
        self.* = undefined;
    }

    fn find(self: *Registry, request_id: []const u8) ?usize {
        for (self.bindings.items, 0..) |binding, index| {
            if (std.mem.eql(u8, binding.request_id, request_id)) return index;
        }
        return null;
    }

    fn commitNoop(_: *anyopaque) error{
        OutOfMemory,
        PermissionCapacityExceeded,
        PermissionCommitFailed,
    }!void {}
};

pub fn preparedRequestFingerprint(
    request: permission_request.PermissionRequest,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.approval.v1\x00");
    hashString(&hash, request.label);
    hashOptional(&hash, request.explanation);
    hashOptional(&hash, request.tool_arguments_preview);
    hashOptional(&hash, request.command);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

pub fn stableApprovalId(
    child_id: []const u8,
    work_id: []const u8,
    prepared: [32]u8,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.approval-id.v1\x00");
    hashString(&hash, child_id);
    hashString(&hash, work_id);
    hash.update(&prepared);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .little);
    hash.update(&length);
    hash.update(value);
}

fn hashOptional(hash: *std.crypto.hash.sha2.Sha256, value: ?[]const u8) void {
    if (value) |text| hashString(hash, text) else hash.update("none\x00");
}

test "approval identity is deterministic" {
    const request = permission_request.PermissionRequest{ .label = "shell.run" };
    const prepared = preparedRequestFingerprint(request);
    try std.testing.expectEqual(
        stableApprovalId("child", "work", prepared),
        stableApprovalId("child", "work", prepared),
    );
}
