const std = @import("std");
const worker_runtime = @import("../agent/worker_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const permission_request = @import("../permissions/permission_request.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const communication = @import("communication.zig");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    RegistryClosed,
    RequestConflict,
    RequestNotFound,
    WrongChild,
    StaleRequest,
    CommitFailed,
    CapacityExceeded,
};

pub const ResolveResult = enum {
    accepted,
    rejected,
    relationship_ready,
};

pub const ObservedResolveResult = struct {
    result: ResolveResult,
    observer_ran: bool = false,
};

pub const RelationshipCompletion = enum {
    succeeded,
    retryable_failure,
    terminal_failure,
};

pub const PersistenceError = error{
    OutOfMemory,
    CommitFailed,
    CapacityExceeded,
};

/// Durable shell supplied by the manager. `commit_response_fn` must revalidate
/// attachment/lifecycle state and, for Always, commit root grants and authority
/// generation before returning.
pub const Persistence = struct {
    context: ?*anyopaque = null,
    register_fn: *const fn (
        ?*anyopaque,
        communication.ApprovalInput,
    ) PersistenceError!void,
    commit_response_fn: *const fn (
        ?*anyopaque,
        communication.ApprovalResponse,
        [32]u8,
    ) PersistenceError!void,
    invalidate_fn: *const fn (
        ?*anyopaque,
        []const u8,
        []const u8,
        communication.ApprovalStatus,
        i64,
    ) PersistenceError!void,

    fn register(self: Persistence, input: communication.ApprovalInput) PersistenceError!void {
        return self.register_fn(self.context, input);
    }

    fn commitResponse(
        self: Persistence,
        response: communication.ApprovalResponse,
        identity_fingerprint: [32]u8,
    ) PersistenceError!void {
        return self.commit_response_fn(
            self.context,
            response,
            identity_fingerprint,
        );
    }

    fn invalidate(
        self: Persistence,
        request_id: []const u8,
        child_id: []const u8,
        status: communication.ApprovalStatus,
        timestamp_ms: i64,
    ) PersistenceError!void {
        return self.invalidate_fn(
            self.context,
            request_id,
            child_id,
            status,
            timestamp_ms,
        );
    }
};

/// A bounded, allocation-free copy of the children currently holding an
/// unresolved approval. Sized well above any realistic count of subagents
/// blocked at one instant; a snapshot that would exceed it reports
/// `truncated` rather than silently naming a subset as the whole set.
pub const max_pending_child_snapshot: usize = 32;
pub const max_pending_child_id_bytes: usize = 64;

pub const PendingChildren = struct {
    storage: [max_pending_child_snapshot][max_pending_child_id_bytes]u8 = undefined,
    lengths: [max_pending_child_snapshot]usize = @splat(0),
    len: usize = 0,
    truncated: bool = false,

    pub fn at(self: *const PendingChildren, index: usize) []const u8 {
        return self.storage[index][0..self.lengths[index]];
    }

    fn contains(self: *const PendingChildren, child_id: []const u8) bool {
        for (0..self.len) |index| {
            if (std.mem.eql(u8, self.at(index), child_id)) return true;
        }
        return false;
    }
};

const Binding = struct {
    request_id: []u8,
    child_id: []u8,
    tool_arguments_preview: ?[]u8 = null,
    prepared_fingerprint: [32]u8,
    identity_fingerprint: [32]u8 = [_]u8{0} ** 32,
    worker: ?*worker_runtime.WorkerRuntime,
    worker_request_id: ?u64,
    worker_route_detached: bool = false,
    relationship_resolution_in_flight: bool = false,

    fn deinit(self: *Binding, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        if (self.tool_arguments_preview) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const PendingRoute = struct {
    request_id: []u8,
    child_id: []u8,
    tool_arguments_preview: ?[]u8 = null,

    pub fn deinit(self: *PendingRoute, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        if (self.tool_arguments_preview) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const PendingRouteSnapshot = struct {
    revision: u64,
    total: usize,
    offset: usize,
    previous_offset: ?usize,
    next_offset: ?usize,
    routes: []PendingRoute,

    pub fn deinit(self: *PendingRouteSnapshot, alloc: Allocator) void {
        for (self.routes) |*route| route.deinit(alloc);
        alloc.free(self.routes);
        self.* = undefined;
    }
};

pub const Registry = struct {
    alloc: Allocator,
    persistence: Persistence,
    mutex: std.Io.Mutex = .init,
    bindings: std.ArrayList(Binding) = .empty,
    closed: bool = false,
    worker_routes_closed: bool = false,
    pending_revision: u64 = 0,

    pub fn pendingRevision(self: *Registry) u64 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.pending_revision;
    }

    /// Returns a bounded, allocator-owned routing projection. Durable approval
    /// content remains owned by the communication ledger.
    pub fn snapshotPendingRoutes(
        self: *Registry,
        alloc: Allocator,
        offset: usize,
        limit: usize,
    ) Error!PendingRouteSnapshot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.RegistryClosed;

        const total = self.bindings.items.len;
        const page_offset = pendingRoutePageOffset(total, offset, limit);
        const count = @min(limit, total - page_offset);
        const routes = try alloc.alloc(PendingRoute, count);
        var built: usize = 0;
        errdefer {
            for (routes[0..built]) |*route| route.deinit(alloc);
            alloc.free(routes);
        }
        for (self.bindings.items[page_offset..][0..count]) |binding| {
            const request_id = try alloc.dupe(u8, binding.request_id);
            errdefer alloc.free(request_id);
            const child_id = try alloc.dupe(u8, binding.child_id);
            errdefer alloc.free(child_id);
            const tool_arguments_preview = if (binding.tool_arguments_preview) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (tool_arguments_preview) |value| alloc.free(value);
            routes[built] = .{
                .request_id = request_id,
                .child_id = child_id,
                .tool_arguments_preview = tool_arguments_preview,
            };
            built += 1;
        }
        return .{
            .revision = self.pending_revision,
            .total = total,
            .offset = page_offset,
            .previous_offset = if (page_offset == 0 or limit == 0)
                null
            else
                page_offset - @min(page_offset, limit),
            .next_offset = if (limit > 0 and page_offset + count < total)
                page_offset + count
            else
                null,
            .routes = routes,
        };
    }

    /// Registers the exact canonical prepared request currently owned by the
    /// worker waiter. The registry stores only routing identity; persistence
    /// owns the bounded projection and prepared fingerprint.
    pub fn registerTool(
        self: *Registry,
        stable_request_id: []const u8,
        child_id: []const u8,
        root_id: []const u8,
        work_id: []const u8,
        request: permission_request.PermissionRequest,
        grants: []const types.PermissionGrant,
        worker: *worker_runtime.WorkerRuntime,
        timestamp_ms: i64,
    ) Error!void {
        const fingerprint = communication.preparedRequestFingerprint(request);
        try self.persistAndAdd(.{
            .id = stable_request_id,
            .kind = .tool,
            .child_id = child_id,
            .root_id = root_id,
            .work_id = work_id,
            .prepared_fingerprint = fingerprint,
            .label = request.label,
            .explanation = request.explanation,
            .command = request.command,
            .file = request.file,
            .grants = grants,
            .created_at_ms = timestamp_ms,
        }, .{
            .request_id = @constCast(stable_request_id),
            .child_id = @constCast(child_id),
            .tool_arguments_preview = if (request.tool_arguments_preview) |value|
                @constCast(value)
            else
                null,
            .prepared_fingerprint = fingerprint,
            .worker = worker,
            .worker_request_id = request.id,
        });
    }

    pub fn registerRelationship(
        self: *Registry,
        stable_request_id: []const u8,
        child_id: []const u8,
        root_id: []const u8,
        action: domain.RelationshipAction,
        prospective_parent_id: []const u8,
        operation_id: []const u8,
        label: []const u8,
        operation_identity_admitted: bool,
        timestamp_ms: i64,
    ) Error!void {
        const prepared_fingerprint = communication.relationshipPreparedFingerprint(
            action,
            child_id,
            prospective_parent_id,
            operation_id,
        );
        try self.persistAndAdd(.{
            .id = stable_request_id,
            .kind = .relationship,
            .child_id = child_id,
            .root_id = root_id,
            .work_id = null,
            .relationship = .{
                .action = action,
                .prospective_parent_id = prospective_parent_id,
                .operation_id = operation_id,
            },
            .prepared_fingerprint = prepared_fingerprint,
            .label = label,
            .explanation = null,
            .grants = &.{},
            .created_at_ms = timestamp_ms,
            .operation_identity_admitted = operation_identity_admitted,
        }, .{
            .request_id = @constCast(stable_request_id),
            .child_id = @constCast(child_id),
            .prepared_fingerprint = prepared_fingerprint,
            .worker = null,
            .worker_request_id = null,
        });
    }

    /// Copies each distinct child holding an unresolved approval into the
    /// caller's bounded buffer.
    ///
    /// The main approval prompt mirrors one child at a time, so nothing on
    /// that surface can name a second child blocked at the same instant. The
    /// registry is the one place that knows all of them. Copying happens under
    /// the mutex so a concurrent resolution cannot free the bytes, and the
    /// call returns before the caller projects anything: no reducer,
    /// projection, or transport work may run under this lock.
    pub fn snapshotPendingChildren(self: *Registry, out: *PendingChildren) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        out.len = 0;
        out.truncated = false;
        if (self.closed) return;
        for (self.bindings.items) |binding| {
            // A detached route has no waiter left to unblock.
            if (binding.worker_route_detached) continue;
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
            out.len += 1;
        }
        if (out.truncated) {
            debug_trace.logf(
                "subagent",
                "pending child attention snapshot truncated bindings={d} captured={d}",
                .{ self.bindings.items.len, out.len },
            );
        }
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

    /// Keeps a stack-owned child worker pinned by the registry while its
    /// response is reserved, observed without the worker mutex, and released.
    /// The registry mutex remains the lifetime pin until the binding is removed.
    pub fn resolveObserved(
        self: *Registry,
        request_id: []const u8,
        child_id: []const u8,
        decision: types.ToolPermissionDecision,
        feedback: ?[]const u8,
        timestamp_ms: i64,
        observer: ?worker_runtime.DecisionObserver,
    ) Error!ObservedResolveResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=registry_closed", .{ traceId(request_id), traceId(child_id) });
            return error.RegistryClosed;
        }
        const index = self.findBinding(request_id) orelse {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=request_not_found", .{ traceId(request_id), traceId(child_id) });
            return error.RequestNotFound;
        };
        const binding = &self.bindings.items[index];
        if (!std.mem.eql(u8, binding.child_id, child_id)) {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=wrong_child", .{ traceId(request_id), traceId(child_id) });
            return error.WrongChild;
        }
        const response: communication.ApprovalResponse = .{
            .request_id = request_id,
            .child_id = child_id,
            .decision = decision,
            .timestamp_ms = timestamp_ms,
        };
        if (binding.worker_route_detached) {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=stale_waiter", .{ traceId(request_id), traceId(child_id) });
            return error.StaleRequest;
        }
        if (binding.worker == null and binding.relationship_resolution_in_flight) {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=relationship_resolution_in_flight", .{ traceId(request_id), traceId(child_id) });
            return .{ .result = .rejected };
        }
        var observer_ran = false;
        if (binding.worker) |worker| {
            const worker_request_id = binding.worker_request_id orelse {
                debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=stale_waiter", .{ traceId(request_id), traceId(child_id) });
                return error.StaleRequest;
            };
            const owned_feedback = if (feedback) |value|
                try self.alloc.dupe(u8, value)
            else
                null;
            var commit_context = CommitContext{
                .persistence = self.persistence,
                .response = response,
                .identity_fingerprint = binding.identity_fingerprint,
            };
            const submission = worker.submitPermissionResponseAfterCommitObserved(
                worker_request_id,
                permission_request.OwnedPermissionResponse.init(
                    self.alloc,
                    decision,
                    owned_feedback,
                ),
                .{
                    .context = &commit_context,
                    .commit_fn = CommitContext.run,
                },
                observer,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PermissionCapacityExceeded => error.CapacityExceeded,
                error.PermissionCommitFailed => error.CommitFailed,
            };
            if (submission != .accepted) {
                debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=stale_waiter", .{ traceId(request_id), traceId(child_id) });
                return .{ .result = .rejected };
            }
            observer_ran = observer != null;
        } else {
            self.persistence.commitResponse(
                response,
                binding.identity_fingerprint,
            ) catch |err| {
                debug_trace.logf("subagent", "approval response commit failed request_id={s} child_id={s} outcome={s}", .{ traceId(request_id), traceId(child_id), @errorName(err) });
                return err;
            };
            if (decision == .once) {
                binding.relationship_resolution_in_flight = true;
                debug_trace.logf("subagent", "relationship approval authorized request_id={s} child_id={s} outcome=ready", .{ traceId(request_id), traceId(child_id) });
                return .{ .result = .relationship_ready };
            }
        }
        self.removeBinding(index);
        self.advancePendingRevision();
        debug_trace.logf("subagent", "approval resolved request_id={s} child_id={s} outcome={s}", .{ traceId(request_id), traceId(child_id), @tagName(decision) });
        return .{
            .result = .accepted,
            .observer_ran = observer_ran,
        };
    }

    pub fn completeRelationship(
        self: *Registry,
        request_id: []const u8,
        child_id: []const u8,
        completion: RelationshipCompletion,
        timestamp_ms: i64,
    ) Error!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.RegistryClosed;
        const index = self.findBinding(request_id) orelse
            return error.RequestNotFound;
        const binding = &self.bindings.items[index];
        if (!std.mem.eql(u8, binding.child_id, child_id)) return error.WrongChild;
        if (binding.worker != null or !binding.relationship_resolution_in_flight) {
            return error.StaleRequest;
        }
        switch (completion) {
            .retryable_failure => {
                binding.relationship_resolution_in_flight = false;
                debug_trace.logf("subagent", "relationship approval continuation released request_id={s} child_id={s} outcome=retryable", .{ traceId(request_id), traceId(child_id) });
                return;
            },
            .terminal_failure => self.persistence.invalidate(
                request_id,
                child_id,
                .stale,
                timestamp_ms,
            ) catch |err| {
                binding.relationship_resolution_in_flight = false;
                debug_trace.logf("subagent", "relationship approval terminalization failed request_id={s} child_id={s} outcome={s}", .{ traceId(request_id), traceId(child_id), @errorName(err) });
                return err;
            },
            .succeeded => {},
        }
        self.removeBinding(index);
        self.advancePendingRevision();
        debug_trace.logf("subagent", "relationship approval continuation completed request_id={s} child_id={s} outcome={s}", .{ traceId(request_id), traceId(child_id), @tagName(completion) });
    }

    /// Retires persisted routes while the registry lock still pins every
    /// stack-owned worker. Failed persistence leaves only a detached, stale
    /// route for a later invalidation retry; every waiter is still denied.
    pub fn invalidateChild(
        self: *Registry,
        child_id: []const u8,
        status: communication.ApprovalStatus,
        timestamp_ms: i64,
    ) Error!usize {
        if (status != .cancelled and status != .stale) return error.CommitFailed;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var first_error: ?PersistenceError = null;
        var changed: usize = 0;
        var index: usize = self.bindings.items.len;
        while (index > 0) {
            index -= 1;
            const binding = &self.bindings.items[index];
            if (!std.mem.eql(u8, binding.child_id, child_id)) continue;
            var persisted = true;
            self.persistence.invalidate(
                binding.request_id,
                child_id,
                status,
                timestamp_ms,
            ) catch |err| {
                persisted = false;
                debug_trace.logf("subagent", "approval invalidation failed request_id={s} child_id={s} outcome={s}", .{ traceId(binding.request_id), traceId(child_id), @errorName(err) });
                if (first_error == null) first_error = err;
            };
            const worker = binding.worker;
            if (persisted) {
                debug_trace.logf("subagent", "approval invalidated request_id={s} child_id={s} outcome={s}", .{ traceId(binding.request_id), traceId(child_id), @tagName(status) });
            } else {
                debug_trace.logf("subagent", "approval worker detached request_id={s} child_id={s} reason=persistence_failed", .{ traceId(binding.request_id), traceId(child_id) });
                binding.worker = null;
                binding.worker_request_id = null;
                binding.worker_route_detached = true;
                if (worker) |value| value.cancelApprovalTurn();
                continue;
            }
            self.removeBinding(index);
            self.advancePendingRevision();
            if (worker) |value| value.cancelApprovalTurn();
            changed += 1;
        }
        if (first_error) |err| return err;
        return changed;
    }

    /// Retires every in-memory worker route before its stack-owned worker can
    /// exit. Durable pending approvals are reconciled by host-exit recovery.
    pub fn detachWorkerRoutes(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.worker_routes_closed = true;

        var index: usize = self.bindings.items.len;
        while (index > 0) {
            index -= 1;
            if (self.bindings.items[index].worker == null) continue;
            debug_trace.logf("subagent", "approval route retired request_id={s} child_id={s} reason=owner_shutdown", .{
                traceId(self.bindings.items[index].request_id),
                traceId(self.bindings.items[index].child_id),
            });
            self.removeBinding(index);
            self.advancePendingRevision();
        }
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.closed = true;
        for (self.bindings.items) |*binding| binding.deinit(self.alloc);
        self.bindings.deinit(self.alloc);
    }

    fn persistAndAdd(
        self: *Registry,
        approval: communication.ApprovalInput,
        input: Binding,
    ) Error!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) {
            debug_trace.logf("subagent", "approval registration failed request_id={s} child_id={s} outcome=registry_closed", .{ traceId(input.request_id), traceId(input.child_id) });
            return error.RegistryClosed;
        }
        if (input.worker != null and self.worker_routes_closed) {
            debug_trace.logf("subagent", "approval registration failed request_id={s} child_id={s} outcome=worker_routes_closed", .{ traceId(input.request_id), traceId(input.child_id) });
            return error.RegistryClosed;
        }
        const identity_fingerprint = communication.approvalIdentityFingerprint(approval);
        if (self.findBinding(input.request_id)) |index| {
            const existing = self.bindings.items[index];
            if (!std.mem.eql(u8, existing.child_id, input.child_id) or
                !std.mem.eql(
                    u8,
                    &existing.identity_fingerprint,
                    &identity_fingerprint,
                ) or existing.worker != input.worker or
                existing.worker_request_id != input.worker_request_id)
            {
                debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=request_conflict", .{ traceId(input.request_id), traceId(input.child_id) });
                return error.RequestConflict;
            }
            return;
        }
        var request_id: ?[]u8 = try self.alloc.dupe(u8, input.request_id);
        errdefer if (request_id) |value| self.alloc.free(value);
        var child_id: ?[]u8 = try self.alloc.dupe(u8, input.child_id);
        errdefer if (child_id) |value| self.alloc.free(value);
        var tool_arguments_preview: ?[]u8 = if (input.tool_arguments_preview) |value|
            try self.alloc.dupe(u8, value)
        else
            null;
        errdefer if (tool_arguments_preview) |value| self.alloc.free(value);
        try self.bindings.append(self.alloc, .{
            .request_id = request_id.?,
            .child_id = child_id.?,
            .tool_arguments_preview = tool_arguments_preview,
            .prepared_fingerprint = input.prepared_fingerprint,
            .identity_fingerprint = identity_fingerprint,
            .worker = input.worker,
            .worker_request_id = input.worker_request_id,
        });
        request_id = null;
        child_id = null;
        tool_arguments_preview = null;
        errdefer {
            var removed = self.bindings.pop().?;
            removed.deinit(self.alloc);
        }
        self.persistence.register(approval) catch |err| {
            debug_trace.logf("subagent", "approval registration failed request_id={s} child_id={s} outcome={s}", .{ traceId(input.request_id), traceId(input.child_id), @errorName(err) });
            return err;
        };
        self.advancePendingRevision();
        debug_trace.logf("subagent", "approval registered request_id={s} child_id={s} outcome=pending", .{ traceId(input.request_id), traceId(input.child_id) });
    }

    fn findBinding(self: *Registry, request_id: []const u8) ?usize {
        for (self.bindings.items, 0..) |binding, index| {
            if (std.mem.eql(u8, binding.request_id, request_id)) return index;
        }
        return null;
    }

    fn removeBinding(self: *Registry, index: usize) void {
        var removed = self.bindings.orderedRemove(index);
        removed.deinit(self.alloc);
    }

    fn advancePendingRevision(self: *Registry) void {
        self.pending_revision = self.pending_revision +| 1;
    }
};

fn traceId(value: []const u8) []const u8 {
    return value[0..@min(value.len, 64)];
}

fn pendingRoutePageOffset(total: usize, requested: usize, limit: usize) usize {
    if (total == 0 or limit == 0) return 0;
    const last_page = ((total - 1) / limit) * limit;
    return @min(requested - (requested % limit), last_page);
}

fn checkPendingRouteSnapshotAllocation(
    alloc: Allocator,
    registry: *Registry,
) !void {
    var snapshot = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 1), snapshot.revision);
    try std.testing.expectEqual(@as(usize, 1), snapshot.routes.len);
    try std.testing.expectEqualStrings("approval-race", snapshot.routes[0].request_id);
    try std.testing.expectEqualStrings("child", snapshot.routes[0].child_id);
}

fn checkLivePreviewRegistryAllocation(alloc: Allocator) !void {
    const FakePersistence = struct {
        fn register(
            _: ?*anyopaque,
            _: communication.ApprovalInput,
        ) PersistenceError!void {}

        fn commit(
            _: ?*anyopaque,
            _: communication.ApprovalResponse,
            _: [32]u8,
        ) PersistenceError!void {}

        fn invalidate(
            _: ?*anyopaque,
            _: []const u8,
            _: []const u8,
            _: communication.ApprovalStatus,
            _: i64,
        ) PersistenceError!void {}
    };

    var worker: worker_runtime.WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var registry = Registry{
        .alloc = alloc,
        .persistence = .{
            .register_fn = FakePersistence.register,
            .commit_response_fn = FakePersistence.commit,
            .invalidate_fn = FakePersistence.invalidate,
        },
    };
    defer registry.deinit();
    try registry.registerTool(
        "preview-approval",
        "child",
        "root",
        "work",
        .{
            .id = 17,
            .label = "mcp_fixture_echo",
            .tool_arguments_preview = "{\"text\":\"sentinel\"}",
        },
        &.{},
        &worker,
        1,
    );
    var snapshot = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqualStrings(
        "{\"text\":\"sentinel\"}",
        snapshot.routes[0].tool_arguments_preview.?,
    );
}

test "child approval registry owns live preview without widening durable input" {
    try std.testing.expect(!@hasField(
        communication.ApprovalInput,
        "tool_arguments_preview",
    ));
    for (0..1_000) |_| {
        try checkLivePreviewRegistryAllocation(std.testing.allocator);
    }
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLivePreviewRegistryAllocation,
        .{},
    );
}

const CommitContext = struct {
    persistence: Persistence,
    response: communication.ApprovalResponse,
    identity_fingerprint: [32]u8,

    fn run(raw: *anyopaque) worker_runtime.WorkerRuntime.PermissionCommitError!void {
        const self: *CommitContext = @ptrCast(@alignCast(raw));
        self.persistence.commitResponse(
            self.response,
            self.identity_fingerprint,
        ) catch |err| {
            debug_trace.logf("subagent", "approval response commit failed request_id={s} child_id={s} outcome={s}", .{ traceId(self.response.request_id), traceId(self.response.child_id), @errorName(err) });
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CommitFailed => error.PermissionCommitFailed,
                error.CapacityExceeded => error.PermissionCapacityExceeded,
            };
        };
    }
};

test "child approval observation completes before worker release" {
    const FakePersistence = struct {
        fn register(
            _: ?*anyopaque,
            _: communication.ApprovalInput,
        ) PersistenceError!void {}

        fn commit(
            _: ?*anyopaque,
            _: communication.ApprovalResponse,
            _: [32]u8,
        ) PersistenceError!void {}

        fn invalidate(
            _: ?*anyopaque,
            _: []const u8,
            _: []const u8,
            _: communication.ApprovalStatus,
            _: i64,
        ) PersistenceError!void {}
    };
    const Registration = struct {
        registry: *Registry,

        fn observe(
            raw: *anyopaque,
            worker: *worker_runtime.WorkerRuntime,
            request: permission_request.PermissionRequest,
        ) error{
            OutOfMemory,
            PermissionRegistrationFailed,
            PermissionCapacityExceeded,
        }!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.registry.registerTool(
                "child-observed-approval",
                "child-session",
                "root-session",
                "work",
                request,
                &.{},
                worker,
                1,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CapacityExceeded => error.PermissionCapacityExceeded,
                else => error.PermissionRegistrationFailed,
            };
        }
    };
    const Waiter = struct {
        worker: *worker_runtime.WorkerRuntime,
        registration: *Registration,
        completed: *std.atomic.Value(bool),
        decision: ?types.ToolPermissionDecision = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            var response = self.worker.requestPermissionBlockingObserved(
                std.testing.allocator,
                .{ .label = "child action" },
                null,
                .{
                    .context = self.registration,
                    .observe_fn = Registration.observe,
                },
            ) catch |err| {
                self.err = err;
                self.completed.store(true, .seq_cst);
                return;
            };
            defer response.deinit();
            self.decision = response.decision;
            self.worker.finishProcessing();
            self.completed.store(true, .seq_cst);
        }
    };
    const BlockingObserver = struct {
        entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        turn_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        fn interface(self: *@This()) worker_runtime.DecisionObserver {
            return .{
                .context = self,
                .observe_fn = observe,
            };
        }

        fn observe(raw: *anyopaque, turn_id: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.turn_id.store(turn_id, .seq_cst);
            self.entered.store(true, .seq_cst);
            while (!self.release.load(.seq_cst)) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }
    };
    const Resolver = struct {
        registry: *Registry,
        observer: *BlockingObserver,
        result: ?ObservedResolveResult = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = self.registry.resolveObserved(
                "child-observed-approval",
                "child-session",
                .once,
                null,
                2,
                self.observer.interface(),
            ) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    const alloc = std.testing.allocator;
    var registry = Registry{
        .alloc = alloc,
        .persistence = .{
            .register_fn = FakePersistence.register,
            .commit_response_fn = FakePersistence.commit,
            .invalidate_fn = FakePersistence.invalidate,
        },
    };
    defer registry.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    worker.worker_processing = true;
    worker.active_turn_id = 97;

    var completed = std.atomic.Value(bool).init(false);
    var registration = Registration{ .registry = &registry };
    var waiter = Waiter{
        .worker = &worker,
        .registration = &registration,
        .completed = &completed,
    };
    const waiter_thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var snapshot = try registry.snapshotPendingRoutes(alloc, 0, 8);
        const registered = snapshot.total == 1;
        snapshot.deinit(alloc);
        if (registered) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(attempts < 100);

    var observer = BlockingObserver{};
    var resolver = Resolver{
        .registry = &registry,
        .observer = &observer,
    };
    const resolver_thread = try std.Thread.spawn(.{}, Resolver.run, .{&resolver});
    while (!observer.entered.load(.seq_cst)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }

    worker.requestStop();
    io_mod.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(!completed.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 97), worker.activeTurnId());
    try std.testing.expectEqual(@as(u64, 97), observer.turn_id.load(.seq_cst));

    observer.release.store(true, .seq_cst);
    resolver_thread.join();
    waiter_thread.join();

    try std.testing.expect(resolver.err == null);
    try std.testing.expectEqual(ResolveResult.accepted, resolver.result.?.result);
    try std.testing.expect(resolver.result.?.observer_ran);
    try std.testing.expect(waiter.err == null);
    try std.testing.expectEqual(types.ToolPermissionDecision.once, waiter.decision.?);
    try std.testing.expect(completed.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), worker.activeTurnId());
}

test "simultaneous approval surfaces resolve one durable request exactly once" {
    const FakePersistence = struct {
        commits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        invalidations: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn register(
            _: ?*anyopaque,
            _: communication.ApprovalInput,
        ) PersistenceError!void {}

        fn commit(
            raw: ?*anyopaque,
            _: communication.ApprovalResponse,
            _: [32]u8,
        ) PersistenceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.commits.fetchAdd(1, .seq_cst);
        }

        fn invalidate(
            raw: ?*anyopaque,
            _: []const u8,
            _: []const u8,
            status: communication.ApprovalStatus,
            _: i64,
        ) PersistenceError!void {
            if (status != .stale) return error.CommitFailed;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.invalidations.fetchAdd(1, .seq_cst);
        }
    };
    const Surface = struct {
        registry: *Registry,
        ready: *std.atomic.Value(usize),
        release: *std.atomic.Value(bool),
        outcome: *std.atomic.Value(u8),

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.release.load(.seq_cst)) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
            const resolved = self.registry.resolve(
                "approval-race",
                "child",
                .once,
                null,
                2,
            ) catch |err| {
                self.outcome.store(
                    if (err == error.RequestNotFound) 2 else 3,
                    .seq_cst,
                );
                return;
            };
            self.outcome.store(switch (resolved) {
                .relationship_ready => 1,
                .rejected => 2,
                .accepted => 3,
            }, .seq_cst);
        }
    };

    var persisted = FakePersistence{};
    var registry = Registry{
        .alloc = std.testing.allocator,
        .persistence = .{
            .context = &persisted,
            .register_fn = FakePersistence.register,
            .commit_response_fn = FakePersistence.commit,
            .invalidate_fn = FakePersistence.invalidate,
        },
    };
    defer registry.deinit();
    try registry.registerRelationship(
        "approval-race",
        "child",
        "root",
        .attach,
        "root",
        "attach-operation",
        "attach child",
        false,
        1,
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPendingRouteSnapshotAllocation,
        .{&registry},
    );

    var ready = std.atomic.Value(usize).init(0);
    var release = std.atomic.Value(bool).init(false);
    var first_outcome = std.atomic.Value(u8).init(0);
    var second_outcome = std.atomic.Value(u8).init(0);
    var first = Surface{
        .registry = &registry,
        .ready = &ready,
        .release = &release,
        .outcome = &first_outcome,
    };
    var second = Surface{
        .registry = &registry,
        .ready = &ready,
        .release = &release,
        .outcome = &second_outcome,
    };
    const first_thread = try std.Thread.spawn(.{}, Surface.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Surface.run, .{&second});
    while (ready.load(.seq_cst) != 2) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    release.store(true, .seq_cst);
    first_thread.join();
    second_thread.join();

    const outcomes = [_]u8{
        first_outcome.load(.seq_cst),
        second_outcome.load(.seq_cst),
    };
    try std.testing.expect((outcomes[0] == 1 and outcomes[1] == 2) or
        (outcomes[0] == 2 and outcomes[1] == 1));
    try std.testing.expectEqual(@as(usize, 1), persisted.commits.load(.seq_cst));
    var refreshed = try registry.snapshotPendingRoutes(std.testing.allocator, 0, 8);
    defer refreshed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), refreshed.revision);
    try std.testing.expectEqual(@as(usize, 1), refreshed.routes.len);
    try registry.completeRelationship(
        "approval-race",
        "child",
        .succeeded,
        3,
    );
    var completed = try registry.snapshotPendingRoutes(std.testing.allocator, 0, 8);
    defer completed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), completed.revision);
    try std.testing.expectEqual(@as(usize, 0), completed.routes.len);
    try registry.registerRelationship(
        "relationship-retry",
        "child",
        "root",
        .reparent,
        "parent",
        "relationship-retry",
        "reparent child",
        true,
        1,
    );
    try std.testing.expectEqual(
        ResolveResult.relationship_ready,
        try registry.resolve(
            "relationship-retry",
            "child",
            .once,
            null,
            2,
        ),
    );
    try registry.completeRelationship(
        "relationship-retry",
        "child",
        .retryable_failure,
        3,
    );
    try std.testing.expectEqual(
        ResolveResult.relationship_ready,
        try registry.resolve(
            "relationship-retry",
            "child",
            .once,
            null,
            4,
        ),
    );
    try registry.completeRelationship(
        "relationship-retry",
        "child",
        .terminal_failure,
        5,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        persisted.commits.load(.seq_cst),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        persisted.invalidations.load(.seq_cst),
    );
    try std.testing.expectError(
        error.RequestNotFound,
        registry.resolve(
            "relationship-retry",
            "child",
            .once,
            null,
            6,
        ),
    );
}

test "child invalidation retires a worker route before a racing response" {
    const BlockingPersistence = struct {
        invalidation_entered: std.atomic.Value(bool) =
            std.atomic.Value(bool).init(false),
        release_invalidation: std.atomic.Value(bool) =
            std.atomic.Value(bool).init(false),

        fn register(
            _: ?*anyopaque,
            _: communication.ApprovalInput,
        ) PersistenceError!void {}

        fn commit(
            _: ?*anyopaque,
            _: communication.ApprovalResponse,
            _: [32]u8,
        ) PersistenceError!void {}

        fn invalidate(
            raw: ?*anyopaque,
            _: []const u8,
            _: []const u8,
            _: communication.ApprovalStatus,
            _: i64,
        ) PersistenceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.invalidation_entered.store(true, .seq_cst);
            while (!self.release_invalidation.load(.seq_cst)) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }
    };
    const Invalidation = struct {
        registry: *Registry,
        outcome: *std.atomic.Value(u8),

        fn run(self: *@This()) void {
            const changed = self.registry.invalidateChild(
                "child",
                .cancelled,
                2,
            ) catch {
                self.outcome.store(2, .seq_cst);
                return;
            };
            self.outcome.store(if (changed == 1) 1 else 2, .seq_cst);
        }
    };
    const Resolution = struct {
        registry: *Registry,
        started: *std.atomic.Value(bool),
        outcome: *std.atomic.Value(u8),

        fn run(self: *@This()) void {
            self.started.store(true, .seq_cst);
            _ = self.registry.resolve(
                "approval-cancel-race",
                "child",
                .once,
                null,
                3,
            ) catch |err| {
                self.outcome.store(
                    if (err == error.RequestNotFound) 1 else 2,
                    .seq_cst,
                );
                return;
            };
            self.outcome.store(2, .seq_cst);
        }
    };

    const alloc = std.testing.allocator;
    var persisted = BlockingPersistence{};
    var registry = Registry{
        .alloc = alloc,
        .persistence = .{
            .context = &persisted,
            .register_fn = BlockingPersistence.register,
            .commit_response_fn = BlockingPersistence.commit,
            .invalidate_fn = BlockingPersistence.invalidate,
        },
    };
    defer registry.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    worker.worker_processing = true;
    worker.pending_permission_waiting = true;
    worker.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{
                .id = 7,
                .label = "blocked action",
                .tool_arguments_preview = "{\"text\":\"race sentinel\"}",
            },
        );
    try registry.registerTool(
        "approval-cancel-race",
        "child",
        "root",
        "work",
        .{
            .id = 7,
            .label = "blocked action",
            .tool_arguments_preview = "{\"text\":\"race sentinel\"}",
        },
        &.{},
        &worker,
        1,
    );
    var pending = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer pending.deinit(alloc);
    try std.testing.expectEqualStrings(
        "{\"text\":\"race sentinel\"}",
        pending.routes[0].tool_arguments_preview.?,
    );

    var invalidation_outcome = std.atomic.Value(u8).init(0);
    var invalidation = Invalidation{
        .registry = &registry,
        .outcome = &invalidation_outcome,
    };
    const invalidation_thread = try std.Thread.spawn(
        .{},
        Invalidation.run,
        .{&invalidation},
    );
    var invalidation_joined = false;
    defer if (!invalidation_joined) {
        persisted.release_invalidation.store(true, .seq_cst);
        invalidation_thread.join();
    };
    while (!persisted.invalidation_entered.load(.seq_cst)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }

    var resolution_started = std.atomic.Value(bool).init(false);
    var resolution_outcome = std.atomic.Value(u8).init(0);
    var resolution = Resolution{
        .registry = &registry,
        .started = &resolution_started,
        .outcome = &resolution_outcome,
    };
    const resolution_thread = try std.Thread.spawn(
        .{},
        Resolution.run,
        .{&resolution},
    );
    var resolution_joined = false;
    defer if (!resolution_joined) resolution_thread.join();
    while (!resolution_started.load(.seq_cst)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    persisted.release_invalidation.store(true, .seq_cst);
    invalidation_thread.join();
    invalidation_joined = true;
    resolution_thread.join();
    resolution_joined = true;

    try std.testing.expectEqual(@as(u8, 1), invalidation_outcome.load(.seq_cst));
    try std.testing.expectEqual(@as(u8, 1), resolution_outcome.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), registry.bindings.items.len);
    try std.testing.expect(worker.pending_permission_response != null);
    try std.testing.expectEqual(
        types.ToolPermissionDecision.deny,
        worker.pending_permission_response.?.decision,
    );
    try std.testing.expectEqualStrings(
        "{\"text\":\"race sentinel\"}",
        pending.routes[0].tool_arguments_preview.?,
    );
}

test "child invalidation failure detaches and wakes the worker route until retry" {
    const FailingPersistence = struct {
        invalidations: std.atomic.Value(usize) =
            std.atomic.Value(usize).init(0),

        fn register(
            _: ?*anyopaque,
            _: communication.ApprovalInput,
        ) PersistenceError!void {}

        fn commit(
            _: ?*anyopaque,
            _: communication.ApprovalResponse,
            _: [32]u8,
        ) PersistenceError!void {
            return error.CommitFailed;
        }

        fn invalidate(
            raw: ?*anyopaque,
            _: []const u8,
            _: []const u8,
            _: communication.ApprovalStatus,
            _: i64,
        ) PersistenceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.invalidations.fetchAdd(1, .seq_cst) == 0) {
                return error.CommitFailed;
            }
        }
    };

    const alloc = std.testing.allocator;
    var persisted = FailingPersistence{};
    var registry = Registry{
        .alloc = alloc,
        .persistence = .{
            .context = &persisted,
            .register_fn = FailingPersistence.register,
            .commit_response_fn = FailingPersistence.commit,
            .invalidate_fn = FailingPersistence.invalidate,
        },
    };
    defer registry.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    worker.worker_processing = true;
    worker.pending_permission_waiting = true;
    worker.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 8, .label = "blocked action" },
        );
    try registry.registerTool(
        "approval-cancel-failure",
        "child",
        "root",
        "work",
        .{ .id = 8, .label = "blocked action" },
        &.{},
        &worker,
        1,
    );

    try std.testing.expectError(
        error.CommitFailed,
        registry.invalidateChild("child", .cancelled, 2),
    );
    try std.testing.expectEqual(@as(usize, 1), registry.bindings.items.len);
    try std.testing.expect(registry.bindings.items[0].worker == null);
    try std.testing.expect(registry.bindings.items[0].worker_route_detached);
    try std.testing.expect(worker.pending_permission_response != null);
    try std.testing.expectEqual(
        types.ToolPermissionDecision.deny,
        worker.pending_permission_response.?.decision,
    );
    try std.testing.expectError(
        error.StaleRequest,
        registry.resolve(
            "approval-cancel-failure",
            "child",
            .once,
            null,
            3,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try registry.invalidateChild("child", .cancelled, 4),
    );
    try std.testing.expectEqual(@as(usize, 0), registry.bindings.items.len);
}

test "capacity rejection publishes no pending approval route" {
    const RejectingPersistence = struct {
        fn register(
            _: ?*anyopaque,
            _: communication.ApprovalInput,
        ) PersistenceError!void {
            return error.CapacityExceeded;
        }

        fn commit(
            _: ?*anyopaque,
            _: communication.ApprovalResponse,
            _: [32]u8,
        ) PersistenceError!void {}

        fn invalidate(
            _: ?*anyopaque,
            _: []const u8,
            _: []const u8,
            _: communication.ApprovalStatus,
            _: i64,
        ) PersistenceError!void {}
    };

    const alloc = std.testing.allocator;
    var registry = Registry{
        .alloc = alloc,
        .persistence = .{
            .register_fn = RejectingPersistence.register,
            .commit_response_fn = RejectingPersistence.commit,
            .invalidate_fn = RejectingPersistence.invalidate,
        },
    };
    defer registry.deinit();
    try std.testing.expectError(
        error.CapacityExceeded,
        registry.registerRelationship(
            "capacity-approval",
            "child",
            "root",
            .attach,
            "root",
            "capacity-operation",
            "attach child",
            false,
            1,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), registry.bindings.items.len);
    try std.testing.expectEqual(@as(u64, 0), registry.pendingRevision());
    var snapshot = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), snapshot.total);
    try std.testing.expectEqual(@as(usize, 0), snapshot.routes.len);
}

test "bounded pending route pages reach every request beyond eight and clamp after resolution" {
    const FakePersistence = struct {
        fn register(
            _: ?*anyopaque,
            _: communication.ApprovalInput,
        ) PersistenceError!void {}

        fn commit(
            _: ?*anyopaque,
            _: communication.ApprovalResponse,
            _: [32]u8,
        ) PersistenceError!void {}

        fn invalidate(
            _: ?*anyopaque,
            _: []const u8,
            _: []const u8,
            _: communication.ApprovalStatus,
            _: i64,
        ) PersistenceError!void {}
    };

    const alloc = std.testing.allocator;
    var registry = Registry{
        .alloc = alloc,
        .persistence = .{
            .register_fn = FakePersistence.register,
            .commit_response_fn = FakePersistence.commit,
            .invalidate_fn = FakePersistence.invalidate,
        },
    };
    defer registry.deinit();

    for (0..10) |index| {
        var request_buf: [32]u8 = undefined;
        const request_id = try std.fmt.bufPrint(&request_buf, "approval-{d:0>2}", .{index});
        var child_buf: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(&child_buf, "child-{d:0>2}", .{index});
        try registry.registerRelationship(
            request_id,
            child_id,
            "root",
            .attach,
            "root",
            request_id,
            "attach child",
            false,
            @intCast(index),
        );
    }

    try std.testing.checkAllAllocationFailures(
        alloc,
        checkPendingRoutePageAllocation,
        .{&registry},
    );

    var first = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 10), first.total);
    try std.testing.expectEqual(@as(usize, 0), first.offset);
    try std.testing.expect(first.previous_offset == null);
    try std.testing.expectEqual(@as(?usize, 8), first.next_offset);
    try std.testing.expectEqual(@as(usize, 8), first.routes.len);
    try std.testing.expectEqualStrings("approval-00", first.routes[0].request_id);
    try std.testing.expectEqualStrings("approval-07", first.routes[7].request_id);

    var second = try registry.snapshotPendingRoutes(alloc, first.next_offset.?, 8);
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 10), second.total);
    try std.testing.expectEqual(@as(usize, 8), second.offset);
    try std.testing.expectEqual(@as(?usize, 0), second.previous_offset);
    try std.testing.expect(second.next_offset == null);
    try std.testing.expectEqual(@as(usize, 2), second.routes.len);
    try std.testing.expectEqualStrings("approval-08", second.routes[0].request_id);
    try std.testing.expectEqualStrings("approval-09", second.routes[1].request_id);

    try std.testing.expectEqual(
        ResolveResult.accepted,
        try registry.resolve("approval-08", "child-08", .deny, null, 11),
    );
    var shortened = try registry.snapshotPendingRoutes(alloc, 8, 8);
    defer shortened.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 9), shortened.total);
    try std.testing.expectEqual(@as(usize, 8), shortened.offset);
    try std.testing.expectEqual(@as(usize, 1), shortened.routes.len);
    try std.testing.expectEqualStrings("approval-09", shortened.routes[0].request_id);

    try std.testing.expectEqual(
        ResolveResult.accepted,
        try registry.resolve("approval-09", "child-09", .deny, null, 12),
    );
    var clamped = try registry.snapshotPendingRoutes(alloc, 8, 8);
    defer clamped.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 8), clamped.total);
    try std.testing.expectEqual(@as(usize, 0), clamped.offset);
    try std.testing.expect(clamped.previous_offset == null);
    try std.testing.expect(clamped.next_offset == null);
    try std.testing.expectEqualStrings("approval-00", clamped.routes[0].request_id);
}

fn checkPendingRoutePageAllocation(alloc: Allocator, registry: *Registry) !void {
    var first = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 10), first.total);
    try std.testing.expectEqual(@as(?usize, 8), first.next_offset);

    var second = try registry.snapshotPendingRoutes(alloc, first.next_offset.?, 8);
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), second.routes.len);
}
