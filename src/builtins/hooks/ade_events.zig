//! Best-effort event feed for agent development environments that host fx.
//!
//! A hosting ADE gives each TUI process an opaque instance identity and a
//! shared Unix socket. Fx emits passive, ordered lifecycle records; delivery
//! failures never change agent behavior.

const std = @import("std");
const builtin = @import("builtin");
const hooks = @import("../../core/hooks/hooks.zig");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const host_target = @import("../../core/hosts/target.zig");
const jsonrpc = @import("../../acp/jsonrpc.zig");
const lifecycle_state = @import("lifecycle_state.zig");
const ade_git_roots = @import("ade_git_roots.zig");

test {
    _ = ade_git_roots;
}

pub const schema_version: u8 = 1;

const delivery_deadline_ms: i64 = 250;
const max_queued_records: usize = 128;
const max_queued_bytes: usize = 8 * 1024 * 1024;
const max_record_bytes: usize = 2 * 1024 * 1024;

const Event = enum {
    fx_started,
    git_root_discovered,
    session_changed,
    prompt_queued,
    turn_started,
    pre_tool_use,
    stop,
    post_turn_end,
    attention_required,
    attention_resolved,
    fx_stopped,

    fn wireName(self: Event) []const u8 {
        return switch (self) {
            .fx_started => "FxStarted",
            .git_root_discovered => "GitRootDiscovered",
            .session_changed => "SessionChanged",
            .prompt_queued => "PromptQueued",
            .turn_started => "TurnStarted",
            .pre_tool_use => "PreToolUse",
            .stop => "Stop",
            .post_turn_end => "PostTurnEnd",
            .attention_required => "AttentionRequired",
            .attention_resolved => "AttentionResolved",
            .fx_stopped => "FxStopped",
        };
    }
};

const AgentRole = enum { main, subagent };

const Context = struct {
    agent_role: AgentRole,
    workspace_root: []const u8,
    session_id: ?[]const u8,
    parent_session_id: ?[]const u8 = null,
    subagent_id: ?u64 = null,
    turn_id: ?u64 = null,
    agent_state: lifecycle_state.AgentState = .idle,
    attention_kind: ?hooks.AttentionKind = null,
};

const Payload = union(Event) {
    fx_started,
    git_root_discovered: struct {
        git_root: []const u8,
        revision: u64,
        reason: []const u8,
    },
    session_changed: struct {
        previous_session_id: ?[]const u8,
        session_id: ?[]const u8,
    },
    prompt_queued,
    turn_started,
    pre_tool_use: struct {
        step_index: usize,
        call_id: []const u8,
        tool_name: []const u8,
        arguments_json: []const u8,
    },
    stop: struct {
        step_index: usize,
        assistant_text: []const u8,
        provider_disposition: []const u8,
        can_continue: bool,
    },
    post_turn_end: struct {
        outcome: []const u8,
        provider_disposition: ?[]const u8,
    },
    attention_required: struct { kind: []const u8 },
    attention_resolved: struct { kind: []const u8 },
    fx_stopped,
};

const QueuedRecord = struct {
    bytes: []u8,
    sequence: u64,
    event: Event,
};

pub const Client = struct {
    enabled: bool = false,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    alloc: ?std.mem.Allocator = null,
    socket_path: []u8 = &.{},
    instance_id: []u8 = &.{},
    workspace_root: []u8 = &.{},
    main_session_id: ?[]u8 = null,
    next_sequence: u64 = 1,
    queue: [max_queued_records]?QueuedRecord = @splat(null),
    queue_head: usize = 0,
    queue_len: usize = 0,
    queued_bytes: usize = 0,
    stopping: bool = false,
    sender_thread: if (host_target.is_wasm) void else ?std.Thread = if (host_target.is_wasm) {} else null,
    lifecycle: ?*lifecycle_state.Reducer = null,
    git_roots: ade_git_roots.Tracker = .{},

    pub fn shouldEnable(socket_path: ?[]const u8, instance_id: ?[]const u8) bool {
        const path = socket_path orelse return false;
        const instance = instance_id orelse return false;
        return path.len > 0 and instance.len > 0;
    }

    pub fn initFromEnv(
        self: *Client,
        alloc: std.mem.Allocator,
        workspace_root: []const u8,
        main_session_id: ?[]const u8,
        lifecycle: *lifecycle_state.Reducer,
    ) void {
        if (comptime host_target.is_wasm or builtin.os.tag == .windows) return;
        const socket_path = io_mod.getenv("FX_ADE_SOCKET_PATH");
        const instance_id = io_mod.getenv("FX_ADE_INSTANCE_ID");
        const checkpoint_path = io_mod.getenv("FX_ADE_CHECKPOINT_PATH");
        const valid_instance = if (instance_id) |value| value.len > 0 else false;

        if (shouldEnable(socket_path, instance_id)) {
            self.init(
                alloc,
                socket_path.?,
                instance_id.?,
                workspace_root,
                main_session_id,
                lifecycle,
            ) catch |err| {
                debug_trace.logf("ade_events", "initialization failed err={s}", .{@errorName(err)});
            };
        }

        const root_sink: ?ade_git_roots.EventSink = if (self.enabled) .{
            .context = self,
            .report_fn = reportGitRootDiscoveredRaw,
        } else null;
        self.git_roots.init(
            alloc,
            if (valid_instance) instance_id.? else "",
            checkpoint_path,
            root_sink,
            .{
                .kind = .interactive,
                .workspace_root = workspace_root,
                .session_id = main_session_id,
            },
        ) catch |err| {
            debug_trace.logf("ade_events", "Git root tracker initialization failed err={s}", .{@errorName(err)});
        };

        if (!self.enabled and !self.git_roots.enabled) {
            debug_trace.logf("ade_events", "disabled socket={s} instance={s} checkpoint={s}", .{
                socket_path orelse "(unset)",
                instance_id orelse "(unset)",
                checkpoint_path orelse "(unset)",
            });
        }
    }

    fn init(
        self: *Client,
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        instance_id: []const u8,
        workspace_root: []const u8,
        main_session_id: ?[]const u8,
        lifecycle: *lifecycle_state.Reducer,
    ) !void {
        const path_copy = try alloc.dupe(u8, socket_path);
        errdefer alloc.free(path_copy);
        const instance_copy = try alloc.dupe(u8, instance_id);
        errdefer alloc.free(instance_copy);
        const workspace_copy = try alloc.dupe(u8, workspace_root);
        errdefer alloc.free(workspace_copy);
        const session_copy = if (main_session_id) |session_id|
            try alloc.dupe(u8, session_id)
        else
            null;

        self.* = .{
            .alloc = alloc,
            .socket_path = path_copy,
            .instance_id = instance_copy,
            .workspace_root = workspace_copy,
            .main_session_id = session_copy,
            .lifecycle = lifecycle,
        };
        self.sender_thread = std.Thread.spawn(.{}, senderMain, .{self}) catch |err| {
            self.freeConfiguration();
            self.* = .{};
            return err;
        };
        self.enabled = true;
        self.enqueue(.fx_started, self.mainContext(null));
    }

    pub fn deinit(self: *Client) void {
        if (comptime host_target.is_wasm) return;
        self.git_roots.deinit();
        const alloc = self.alloc orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (self.enabled) {
            self.clearQueueLocked(alloc);
            self.emitLocked(.fx_stopped, self.mainContext(null));
        }
        self.enabled = false;
        self.stopping = true;
        self.wake.broadcast(io);
        self.mutex.unlock(io);

        if (self.sender_thread) |thread| thread.join();

        self.mutex.lockUncancelable(io);
        self.clearQueueLocked(alloc);
        self.mutex.unlock(io);
        self.freeConfiguration();
        self.* = .{};
    }

    pub fn reportSessionChanged(self: *Client, main_session_id: ?[]const u8) void {
        if (!self.enabled) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.reportSessionChangeLocked(main_session_id, self.workspace_root);
    }

    pub fn reportPromptQueued(self: *Client) void {
        if (!self.enabled) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.emitLocked(.prompt_queued, self.mainContext(null));
    }

    pub fn reportTurnStarted(self: *Client, invocation: hooks.Invocation) void {
        self.reportInvocation(.turn_started, invocation);
    }

    pub fn reportPreToolUse(self: *Client, input: hooks.PreToolUseInput) void {
        self.reportInvocation(.{ .pre_tool_use = .{
            .step_index = input.step_index,
            .call_id = input.call_id,
            .tool_name = input.tool_name,
            .arguments_json = input.arguments_json,
        } }, input.invocation);
    }

    pub fn reportStop(self: *Client, input: hooks.StopInput) void {
        self.reportInvocation(.{ .stop = .{
            .step_index = input.step_index,
            .assistant_text = input.assistant_text,
            .provider_disposition = @tagName(input.provider_disposition),
            .can_continue = input.can_continue,
        } }, input.invocation);
    }

    pub fn reportPostTurnEnd(self: *Client, input: hooks.PostTurnEndInput) void {
        self.reportInvocation(.{ .post_turn_end = .{
            .outcome = @tagName(input.outcome),
            .provider_disposition = if (input.provider_disposition) |value| @tagName(value) else null,
        } }, input.invocation);
    }

    pub fn reportAttentionRequired(self: *Client, input: hooks.AttentionRequiredInput) void {
        self.reportInvocation(.{ .attention_required = .{
            .kind = @tagName(input.kind),
        } }, input.invocation);
    }

    pub fn reportAttentionResolved(self: *Client, input: hooks.AttentionResolvedInput) void {
        self.reportInvocation(.{ .attention_resolved = .{
            .kind = @tagName(input.kind),
        } }, input.invocation);
    }

    fn reportGitRootDiscoveredRaw(raw: *anyopaque, discovery: ade_git_roots.Discovery) void {
        const self: *Client = @ptrCast(@alignCast(raw));
        self.reportGitRootDiscovered(discovery);
    }

    fn reportGitRootDiscovered(self: *Client, discovery: ade_git_roots.Discovery) void {
        if (!self.enabled) return;
        const role = roleForScope(discovery.scope.kind) orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const snapshot = self.stateFor(role, discovery.scope.session_id, discovery.scope.subagent_id);
        self.emitLocked(.{ .git_root_discovered = .{
            .git_root = discovery.root,
            .revision = discovery.revision,
            .reason = discovery.reason.wireName(),
        } }, .{
            .agent_role = role,
            .workspace_root = discovery.scope.workspace_root,
            .session_id = discovery.scope.session_id,
            .parent_session_id = if (role == .subagent) self.main_session_id else null,
            .subagent_id = discovery.scope.subagent_id,
            .agent_state = snapshot.agent_state,
            .attention_kind = snapshot.attention_kind,
        });
    }

    fn reportInvocation(self: *Client, payload: Payload, invocation: hooks.Invocation) void {
        if (!self.enabled) return;
        const role = roleForScope(invocation.scope.kind) orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        // Session installation reports eagerly. Keep this defensive update so
        // a future main-agent entrypoint cannot silently publish stale context.
        if (role == .main) {
            self.reportSessionChangeLocked(
                invocation.scope.session_id,
                invocation.scope.workspace_root,
            );
        }
        const snapshot = self.stateFor(role, invocation.scope.session_id, invocation.scope.subagent_id);
        self.emitLocked(payload, .{
            .agent_role = role,
            .workspace_root = invocation.scope.workspace_root,
            .session_id = invocation.scope.session_id,
            .parent_session_id = if (role == .subagent) self.main_session_id else null,
            .subagent_id = invocation.scope.subagent_id,
            .turn_id = invocation.turn_id,
            .agent_state = snapshot.agent_state,
            .attention_kind = snapshot.attention_kind,
        });
    }

    fn reportSessionChangeLocked(
        self: *Client,
        next_session: ?[]const u8,
        workspace_root: []const u8,
    ) void {
        if (optionalStringsEqual(self.main_session_id, next_session)) return;
        const alloc = self.alloc orelse return;
        const next_session_id = if (next_session) |session_id|
            alloc.dupe(u8, session_id) catch return
        else
            null;
        const previous_session_id = self.main_session_id;
        self.main_session_id = next_session_id;
        const snapshot = self.stateFor(.main, self.main_session_id, null);
        self.emitLocked(.{ .session_changed = .{
            .previous_session_id = previous_session_id,
            .session_id = self.main_session_id,
        } }, .{
            .agent_role = .main,
            .workspace_root = workspace_root,
            .session_id = self.main_session_id,
            .agent_state = snapshot.agent_state,
            .attention_kind = snapshot.attention_kind,
        });
        if (previous_session_id) |session_id| alloc.free(session_id);
    }

    fn mainContext(self: *const Client, turn_id: ?u64) Context {
        const snapshot = self.stateFor(.main, self.main_session_id, null);
        return .{
            .agent_role = .main,
            .workspace_root = self.workspace_root,
            .session_id = self.main_session_id,
            .turn_id = turn_id,
            .agent_state = snapshot.agent_state,
            .attention_kind = snapshot.attention_kind,
        };
    }

    fn stateFor(
        self: *const Client,
        role: AgentRole,
        session_id: ?[]const u8,
        subagent_id: ?u64,
    ) lifecycle_state.Snapshot {
        const lifecycle = self.lifecycle orelse return .{};
        const agent: lifecycle_state.Agent = switch (role) {
            .main => .main,
            .subagent => if (session_id) |value|
                .{ .subagent_session = value }
            else if (subagent_id) |value|
                .{ .subagent_id = value }
            else
                .anonymous_subagent,
        };
        return lifecycle.snapshot(agent);
    }

    fn enqueue(self: *Client, payload: Payload, context: Context) void {
        if (!self.enabled) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.emitLocked(payload, context);
    }

    fn emitLocked(self: *Client, payload: Payload, context: Context) void {
        const sequence = self.next_sequence;
        self.next_sequence += 1;
        const event = std.meta.activeTag(payload);
        const alloc = self.alloc orelse return;
        if (recordUpperBound(self.instance_id, payload, context) > max_record_bytes) {
            debug_trace.logf("ade_events", "record dropped event={s} sequence={d} reason=record_too_large", .{
                event.wireName(),
                sequence,
            });
            return;
        }

        const bytes = serializeRecord(
            alloc,
            sequence,
            self.instance_id,
            payload,
            context,
        ) catch |err| {
            debug_trace.logf("ade_events", "record dropped event={s} sequence={d} err={s}", .{
                event.wireName(),
                sequence,
                @errorName(err),
            });
            return;
        };
        if (self.queue_len == max_queued_records or
            bytes.len > max_queued_bytes -| self.queued_bytes)
        {
            alloc.free(bytes);
            debug_trace.logf("ade_events", "record dropped event={s} sequence={d} reason=queue_full", .{
                event.wireName(),
                sequence,
            });
            return;
        }
        const tail = (self.queue_head + self.queue_len) % max_queued_records;
        self.queue[tail] = .{
            .bytes = bytes,
            .sequence = sequence,
            .event = event,
        };
        self.queue_len += 1;
        self.queued_bytes += bytes.len;
        self.wake.signal(io_mod.getIo());
    }

    fn takeLocked(self: *Client) ?QueuedRecord {
        if (self.queue_len == 0) return null;
        const record = self.queue[self.queue_head].?;
        self.queue[self.queue_head] = null;
        self.queue_head = (self.queue_head + 1) % max_queued_records;
        self.queue_len -= 1;
        self.queued_bytes -= record.bytes.len;
        return record;
    }

    fn clearQueueLocked(self: *Client, alloc: std.mem.Allocator) void {
        while (self.takeLocked()) |record| alloc.free(record.bytes);
        self.queue_head = 0;
    }

    fn freeConfiguration(self: *Client) void {
        const alloc = self.alloc orelse return;
        if (self.socket_path.len > 0) alloc.free(self.socket_path);
        if (self.instance_id.len > 0) alloc.free(self.instance_id);
        if (self.workspace_root.len > 0) alloc.free(self.workspace_root);
        if (self.main_session_id) |session_id| alloc.free(session_id);
    }

    fn senderMain(self: *Client) void {
        const io = io_mod.getIo();
        const alloc = self.alloc orelse return;
        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.queue_len == 0 and !self.stopping) {
                self.wake.waitUncancelable(io, &self.mutex);
            }
            const record = self.takeLocked();
            const should_stop = self.stopping and record == null;
            self.mutex.unlock(io);
            if (should_stop) return;
            if (record) |queued| {
                sendRecordWithDeadline(self.socket_path, queued.bytes) catch |err| {
                    debug_trace.logf("ade_events", "send failed event={s} sequence={d} err={s}", .{
                        queued.event.wireName(),
                        queued.sequence,
                        @errorName(err),
                    });
                };
                alloc.free(queued.bytes);
            }
        }
    }

    fn serializeRecord(
        alloc: std.mem.Allocator,
        sequence: u64,
        instance_id: []const u8,
        payload: Payload,
        context: Context,
    ) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        try writeRecord(alloc, &output.writer, sequence, instance_id, payload, context);
        return output.toOwnedSlice();
    }
};

fn roleForScope(scope: hooks.ScopeKind) ?AgentRole {
    return switch (scope) {
        .interactive => .main,
        .subagent => .subagent,
        .ask, .acp => null,
    };
}

fn optionalStringsEqual(first: ?[]const u8, second: ?[]const u8) bool {
    if (first == null or second == null) return first == null and second == null;
    return std.mem.eql(u8, first.?, second.?);
}

fn recordUpperBound(
    instance_id: []const u8,
    payload: Payload,
    context: Context,
) usize {
    var total: usize = 512;
    total +|= escapedUpperBound(instance_id);
    total +|= escapedUpperBound(context.workspace_root);
    if (context.session_id) |value| total +|= escapedUpperBound(value);
    if (context.parent_session_id) |value| total +|= escapedUpperBound(value);
    switch (payload) {
        .session_changed => |value| {
            if (value.previous_session_id) |session_id| total +|= escapedUpperBound(session_id);
            if (value.session_id) |session_id| total +|= escapedUpperBound(session_id);
        },
        .git_root_discovered => |value| {
            total +|= escapedUpperBound(value.git_root);
            total +|= escapedUpperBound(value.reason);
        },
        .pre_tool_use => |value| {
            total +|= escapedUpperBound(value.call_id);
            total +|= escapedUpperBound(value.tool_name);
            total +|= value.arguments_json.len;
        },
        .stop => |value| {
            total +|= escapedUpperBound(value.assistant_text);
            total +|= escapedUpperBound(value.provider_disposition);
        },
        .post_turn_end => |value| {
            total +|= escapedUpperBound(value.outcome);
            if (value.provider_disposition) |disposition| total +|= escapedUpperBound(disposition);
        },
        .attention_required => |value| total +|= escapedUpperBound(value.kind),
        .attention_resolved => |value| total +|= escapedUpperBound(value.kind),
        .fx_started, .prompt_queued, .turn_started, .fx_stopped => {},
    }
    return total;
}

fn escapedUpperBound(value: []const u8) usize {
    return std.math.mul(usize, value.len, 6) catch std.math.maxInt(usize);
}

fn sendRecordWithDeadline(socket_path: []const u8, bytes: []const u8) !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi or host_target.is_wasm) {
        return error.SocketUnavailable;
    }
    return sendRecordPosix(socket_path, bytes);
}

fn sendRecordPosix(socket_path: []const u8, bytes: []const u8) !void {
    var address: std.posix.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&address), 0);
    if (socket_path.len >= address.path.len) return error.NameTooLong;
    if (@hasField(std.posix.sockaddr.un, "len")) {
        address.len = @sizeOf(std.posix.sockaddr.un);
    }
    address.family = std.posix.AF.UNIX;
    @memcpy(address.path[0..socket_path.len], socket_path);
    const address_len: std.posix.socklen_t = @intCast(
        @offsetOf(std.posix.sockaddr.un, "path") + socket_path.len + 1,
    );

    const raw_socket = std.posix.system.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
    );
    if (std.posix.errno(raw_socket) != .SUCCESS) return error.SocketOpenFailed;
    const socket: std.posix.socket_t = @intCast(raw_socket);
    defer closeSocket(socket);
    try setNonblocking(socket);

    const io = io_mod.getIo();
    const deadline_ns = std.Io.Timestamp.now(io, .awake).nanoseconds +
        delivery_deadline_ms * std.time.ns_per_ms;
    while (true) {
        try requireBeforeDeadline(deadline_ns);
        const result = std.posix.system.connect(
            socket,
            @ptrCast(&address),
            address_len,
        );
        switch (std.posix.errno(result)) {
            .SUCCESS => break,
            .INTR => continue,
            .AGAIN, .INPROGRESS => {
                try waitWritableUntil(socket, deadline_ns);
                try requireConnected(socket);
                break;
            },
            else => return error.ConnectFailed,
        }
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        try requireBeforeDeadline(deadline_ns);
        var iovec = std.posix.iovec_const{
            .base = bytes[offset..].ptr,
            .len = bytes.len - offset,
        };
        var message: std.posix.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iovec),
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        const flags = if (@hasDecl(std.posix.MSG, "NOSIGNAL")) std.posix.MSG.NOSIGNAL else 0;
        const result = std.posix.system.sendmsg(socket, &message, flags);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                const written: usize = @intCast(result);
                if (written == 0) return error.WriteFailed;
                offset += written;
            },
            .INTR => continue,
            .AGAIN => try waitWritableUntil(socket, deadline_ns),
            else => return error.WriteFailed,
        }
    }
}

fn requireBeforeDeadline(deadline_ns: i96) !void {
    if (std.Io.Timestamp.now(io_mod.getIo(), .awake).nanoseconds >= deadline_ns) {
        return error.DeliveryTimedOut;
    }
}

fn setNonblocking(socket: std.posix.socket_t) !void {
    const nonblocking = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const status_result = std.posix.system.fcntl(socket, std.posix.F.SETFL, nonblocking);
    if (std.posix.errno(status_result) != .SUCCESS) return error.SocketConfigureFailed;
    const descriptor_result = std.posix.system.fcntl(
        socket,
        std.posix.F.SETFD,
        @as(usize, std.posix.FD_CLOEXEC),
    );
    if (std.posix.errno(descriptor_result) != .SUCCESS) return error.SocketConfigureFailed;
}

fn waitWritableUntil(socket: std.posix.socket_t, deadline_ns: i96) !void {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = socket,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    while (true) {
        const now_ns = std.Io.Timestamp.now(io_mod.getIo(), .awake).nanoseconds;
        if (now_ns >= deadline_ns) return error.DeliveryTimedOut;
        const remaining_ns = deadline_ns - now_ns;
        const remaining_ms: i32 = @intCast(@max(
            1,
            @divFloor(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms),
        ));
        descriptors[0].revents = 0;
        const result = std.posix.system.poll(
            &descriptors,
            @as(std.posix.nfds_t, descriptors.len),
            remaining_ms,
        );
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.DeliveryTimedOut;
                if ((descriptors[0].revents & std.posix.POLL.NVAL) != 0) {
                    return error.SocketUnavailable;
                }
                return;
            },
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

fn requireConnected(socket: std.posix.socket_t) !void {
    var socket_error: c_int = 0;
    var error_len: std.posix.socklen_t = @sizeOf(c_int);
    const result = std.posix.system.getsockopt(
        socket,
        std.posix.SOL.SOCKET,
        std.posix.SO.ERROR,
        &socket_error,
        &error_len,
    );
    if (std.posix.errno(result) != .SUCCESS or socket_error != 0) {
        return error.ConnectFailed;
    }
}

fn closeSocket(socket: std.posix.socket_t) void {
    _ = std.posix.system.close(socket);
}

fn writeRecord(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    sequence: u64,
    instance_id: []const u8,
    payload: Payload,
    context: Context,
) !void {
    try writer.writeAll("{\"schema_version\":");
    try writer.print("{d}", .{schema_version});
    try writer.writeAll(",\"sequence\":");
    try writer.print("{d}", .{sequence});
    try writer.writeAll(",\"event\":");
    try jsonrpc.writeJsonStr(std.meta.activeTag(payload).wireName(), writer);
    try writer.writeAll(",\"instance_id\":");
    try jsonrpc.writeJsonStr(instance_id, writer);
    try writer.writeAll(",\"context\":{\"agent_role\":");
    try jsonrpc.writeJsonStr(@tagName(context.agent_role), writer);
    try writer.writeAll(",\"workspace_root\":");
    try jsonrpc.writeJsonStr(context.workspace_root, writer);
    try writer.writeAll(",\"session_id\":");
    try writeOptionalString(writer, context.session_id);
    try writer.writeAll(",\"parent_session_id\":");
    try writeOptionalString(writer, context.parent_session_id);
    try writer.writeAll(",\"subagent_id\":");
    try writeOptionalInteger(writer, context.subagent_id);
    try writer.writeAll(",\"turn_id\":");
    try writeOptionalInteger(writer, context.turn_id);
    try writer.writeAll(",\"agent_state\":");
    try jsonrpc.writeJsonStr(@tagName(context.agent_state), writer);
    try writer.writeAll(",\"attention_kind\":");
    if (context.attention_kind) |kind|
        try jsonrpc.writeJsonStr(@tagName(kind), writer)
    else
        try writer.writeAll("null");
    try writer.writeAll("},\"payload\":");
    try writePayload(alloc, writer, payload);
    try writer.writeAll("}\n");
}

fn writePayload(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    payload: Payload,
) !void {
    switch (payload) {
        .fx_started, .prompt_queued, .turn_started, .fx_stopped => try writer.writeAll("{}"),
        .git_root_discovered => |value| {
            try writer.writeAll("{\"git_root\":");
            try jsonrpc.writeJsonStr(value.git_root, writer);
            try writer.print(",\"revision\":{d},\"reason\":", .{value.revision});
            try jsonrpc.writeJsonStr(value.reason, writer);
            try writer.writeAll("}");
        },
        .session_changed => |value| {
            try writer.writeAll("{\"previous_session_id\":");
            try writeOptionalString(writer, value.previous_session_id);
            try writer.writeAll(",\"session_id\":");
            try writeOptionalString(writer, value.session_id);
            try writer.writeAll("}");
        },
        .pre_tool_use => |value| {
            try writer.writeAll("{\"step_index\":");
            try writer.print("{d}", .{value.step_index});
            try writer.writeAll(",\"call_id\":");
            try jsonrpc.writeJsonStr(value.call_id, writer);
            try writer.writeAll(",\"tool_name\":");
            try jsonrpc.writeJsonStr(value.tool_name, writer);
            try writer.writeAll(",\"arguments\":");
            try writeCompactJson(alloc, writer, value.arguments_json);
            try writer.writeAll("}");
        },
        .stop => |value| {
            try writer.writeAll("{\"step_index\":");
            try writer.print("{d}", .{value.step_index});
            try writer.writeAll(",\"assistant_text\":");
            try jsonrpc.writeJsonStr(value.assistant_text, writer);
            try writer.writeAll(",\"provider_disposition\":");
            try jsonrpc.writeJsonStr(value.provider_disposition, writer);
            try writer.print(",\"can_continue\":{s}", .{if (value.can_continue) "true" else "false"});
            try writer.writeAll("}");
        },
        .post_turn_end => |value| {
            try writer.writeAll("{\"outcome\":");
            try jsonrpc.writeJsonStr(value.outcome, writer);
            try writer.writeAll(",\"provider_disposition\":");
            try writeOptionalString(writer, value.provider_disposition);
            try writer.writeAll("}");
        },
        .attention_required => |value| {
            try writer.writeAll("{\"kind\":");
            try jsonrpc.writeJsonStr(value.kind, writer);
            try writer.writeAll("}");
        },
        .attention_resolved => |value| {
            try writer.writeAll("{\"kind\":");
            try jsonrpc.writeJsonStr(value.kind, writer);
            try writer.writeAll("}");
        },
    }
}

/// Answers whether these caller-supplied bytes can be spliced into a record.
///
/// Two questions, in this order. Framing: no raw byte below 0x20 may appear
/// inside a string, because a raw newline there splits one record into two
/// physical lines and the consumer decodes the remainder as garbage. The
/// emitter asks that itself rather than inheriting whatever a scanner chooses
/// to tolerate, because the NDJSON framing invariant is the emitter's own.
/// Validity: the bytes must parse, because splicing a malformed value in
/// corrupts the enclosing record just as surely as a broken line does.
///
/// The emitter does not trust its caller here. The integrity flag fx relies
/// on elsewhere defaults to valid and is not set on every path that builds
/// tool arguments, so unclassified bytes are the ordinary case rather than
/// the exception.
fn compactJsonIsAdmissible(alloc: std.mem.Allocator, value: []const u8) bool {
    if (value.len == 0) return false;
    var in_string = false;
    var escaped = false;
    for (value) |byte| {
        if (in_string) {
            if (byte < 0x20) return false;
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (byte == '"') in_string = true;
    }
    return std.json.validate(alloc, value) catch false;
}

fn writeCompactJson(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: []const u8,
) !void {
    if (!compactJsonIsAdmissible(alloc, value)) {
        debug_trace.logf(
            "ade_events",
            "tool arguments replaced bytes={d} reason=unframable_json",
            .{value.len},
        );
        try writer.writeAll("{}");
        return;
    }
    var in_string = false;
    var escaped = false;
    for (value) |byte| {
        if (in_string) {
            try writer.writeByte(byte);
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (std.ascii.isWhitespace(byte)) continue;
        try writer.writeByte(byte);
        if (byte == '"') in_string = true;
    }
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |string| try jsonrpc.writeJsonStr(string, writer) else try writer.writeAll("null");
}

fn writeOptionalInteger(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |integer| try writer.print("{d}", .{integer}) else try writer.writeAll("null");
}

test "ADE feed requires a socket and opaque instance identity" {
    try std.testing.expect(Client.shouldEnable("/tmp/ade.sock", "instance-3"));
    try std.testing.expect(!Client.shouldEnable(null, "instance-3"));
    try std.testing.expect(!Client.shouldEnable("/tmp/ade.sock", null));
    try std.testing.expect(!Client.shouldEnable("", "instance-3"));
    try std.testing.expect(!Client.shouldEnable("/tmp/ade.sock", ""));
}

test "ADE feed serializes a main turn as one versioned JSON line" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRecord(std.testing.allocator, &output.writer, 7, "pane-3", .turn_started, .{
        .agent_role = .main,
        .workspace_root = "/tmp/workspace",
        .session_id = "main-session",
        .turn_id = 42,
    });

    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"sequence\":7,\"event\":\"TurnStarted\"," ++
            "\"instance_id\":\"pane-3\",\"context\":{\"agent_role\":\"main\"," ++
            "\"workspace_root\":\"/tmp/workspace\",\"session_id\":\"main-session\"," ++
            "\"parent_session_id\":null,\"subagent_id\":null,\"turn_id\":42," ++
            "\"agent_state\":\"idle\",\"attention_kind\":null},\"payload\":{}}\n",
        output.written(),
    );
}

test "ADE feed serializes attention resolution with a working snapshot" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRecord(std.testing.allocator, &output.writer, 12, "pane-3", .{ .attention_resolved = .{
        .kind = "route_recovery",
    } }, .{
        .agent_role = .main,
        .workspace_root = "/tmp/workspace",
        .session_id = "main-session",
        .turn_id = 42,
        .agent_state = .working,
    });

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("AttentionResolved", parsed.value.object.get("event").?.string);
    const context = parsed.value.object.get("context").?.object;
    try std.testing.expectEqualStrings("working", context.get("agent_state").?.string);
    try std.testing.expect(context.get("attention_kind").? == .null);
    const payload = parsed.value.object.get("payload").?.object;
    try std.testing.expectEqualStrings("route_recovery", payload.get("kind").?.string);
}

test "ADE feed serializes an additive Git root discovery record" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRecord(&output.writer, 2, "instance-17", .{ .git_root_discovered = .{
        .git_root = "/workspace/linked-root",
        .revision = 3,
        .reason = "subagent_file_mutation",
    } }, .{
        .agent_role = .subagent,
        .workspace_root = "/workspace/project",
        .session_id = "child-session",
        .parent_session_id = "main-session",
        .subagent_id = 9,
    });

    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"sequence\":2,\"event\":\"GitRootDiscovered\"," ++
            "\"instance_id\":\"instance-17\",\"context\":{\"agent_role\":\"subagent\"," ++
            "\"workspace_root\":\"/workspace/project\",\"session_id\":\"child-session\"," ++
            "\"parent_session_id\":\"main-session\",\"subagent_id\":9,\"turn_id\":null," ++
            "\"agent_state\":\"idle\",\"attention_kind\":null}," ++
            "\"payload\":{\"git_root\":\"/workspace/linked-root\",\"revision\":3," ++
            "\"reason\":\"subagent_file_mutation\"}}\n",
        output.written(),
    );
}
test "ADE feed keeps child and parent identities on subagent tool events" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRecord(std.testing.allocator, &output.writer, 8, "pane-3", .{ .pre_tool_use = .{
        .step_index = 2,
        .call_id = "call-1",
        .tool_name = "read_file",
        .arguments_json = "{\"path\":\"a\\\"b\"}",
    } }, .{
        .agent_role = .subagent,
        .workspace_root = "/tmp/workspace",
        .session_id = "child-session",
        .parent_session_id = "main-session",
        .subagent_id = 11,
        .turn_id = 43,
    });

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("PreToolUse", parsed.value.object.get("event").?.string);
    const context = parsed.value.object.get("context").?.object;
    try std.testing.expectEqualStrings("subagent", context.get("agent_role").?.string);
    try std.testing.expectEqualStrings("child-session", context.get("session_id").?.string);
    try std.testing.expectEqualStrings("main-session", context.get("parent_session_id").?.string);
    try std.testing.expectEqual(@as(i64, 11), context.get("subagent_id").?.integer);
    try std.testing.expectEqualStrings("idle", context.get("agent_state").?.string);
    try std.testing.expect(context.get("attention_kind").? == .null);
    const arguments = parsed.value.object.get("payload").?.object.get("arguments").?.object;
    try std.testing.expectEqualStrings("a\"b", arguments.get("path").?.string);
}

test "ADE feed compacts tool JSON so valid whitespace cannot split NDJSON framing" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRecord(std.testing.allocator, &output.writer, 9, "pane-3", .{ .pre_tool_use = .{
        .step_index = 1,
        .call_id = "call-2",
        .tool_name = "terminal",
        .arguments_json = "{\n  \"command\": \"printf \\\\n\",\n  \"enabled\": true\n}\n",
    } }, .{
        .agent_role = .main,
        .workspace_root = "/tmp/workspace",
        .session_id = "main-session",
        .turn_id = 45,
    });

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "\n"));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const arguments = parsed.value.object.get("payload").?.object.get("arguments").?.object;
    try std.testing.expectEqualStrings("printf \\n", arguments.get("command").?.string);
    try std.testing.expect(arguments.get("enabled").?.bool);
}

test "ADE scope projection excludes ask and ACP processes" {
    try std.testing.expectEqual(AgentRole.main, roleForScope(.interactive).?);
    try std.testing.expectEqual(AgentRole.subagent, roleForScope(.subagent).?);
    try std.testing.expect(roleForScope(.ask) == null);
    try std.testing.expect(roleForScope(.acp) == null);
}

test "ADE session changes publish eagerly before child lifecycle context" {
    const alloc = std.testing.allocator;
    var lifecycle = lifecycle_state.Reducer{};
    lifecycle.init(alloc);
    defer lifecycle.deinit();
    var client = Client{
        .enabled = true,
        .alloc = alloc,
        .socket_path = try alloc.dupe(u8, "/tmp/unused-ade.sock"),
        .instance_id = try alloc.dupe(u8, "instance-4"),
        .workspace_root = try alloc.dupe(u8, "/tmp/workspace"),
        .main_session_id = try alloc.dupe(u8, "old-main"),
        .lifecycle = &lifecycle,
    };
    defer client.deinit();

    _ = lifecycle.transition(.main, .prompt_queued, null);
    client.reportPromptQueued();
    client.reportSessionChanged("new-main");
    _ = lifecycle.transition(.{ .subagent_session = "child-session" }, .turn_started, null);
    client.reportTurnStarted(.{
        .scope = .{
            .kind = .subagent,
            .workspace_root = "/tmp/workspace",
            .session_id = "child-session",
            .subagent_id = 9,
        },
        .turn_id = 44,
    });

    try std.testing.expectEqual(@as(usize, 3), client.queue_len);
    const expected_events = [_][]const u8{ "PromptQueued", "SessionChanged", "TurnStarted" };
    for (expected_events, 0..) |expected_event, index| {
        const queued = client.queue[index].?;
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, queued.bytes, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(expected_event, parsed.value.object.get("event").?.string);
        try std.testing.expectEqual(@as(i64, @intCast(index + 1)), parsed.value.object.get("sequence").?.integer);
        if (index == 2) {
            const context = parsed.value.object.get("context").?.object;
            try std.testing.expectEqualStrings("child-session", context.get("session_id").?.string);
            try std.testing.expectEqualStrings("new-main", context.get("parent_session_id").?.string);
            try std.testing.expectEqualStrings("working", context.get("agent_state").?.string);
            try std.testing.expect(context.get("attention_kind").? == .null);
        } else {
            const context = parsed.value.object.get("context").?.object;
            try std.testing.expectEqualStrings("working", context.get("agent_state").?.string);
        }
    }
}

fn testUnixSocketPath(alloc: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "ade.sock" });
}

fn elapsedAwakeMillis(started: std.Io.Timestamp) i64 {
    const elapsed = std.Io.Timestamp.now(io_mod.getIo(), .awake).nanoseconds - started.nanoseconds;
    return @intCast(@divFloor(elapsed, std.time.ns_per_ms));
}

test "ADE delivery fails quickly when the receiver socket is missing" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_path = try testUnixSocketPath(alloc, tmp.dir);
    defer alloc.free(socket_path);

    const started = std.Io.Timestamp.now(io_mod.getIo(), .awake);
    try std.testing.expectError(error.ConnectFailed, sendRecordWithDeadline(socket_path, "{}\n"));
    try std.testing.expect(elapsedAwakeMillis(started) < 2_000);
}

test "ADE delivery has one total deadline when a listener never reads" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_path = try testUnixSocketPath(alloc, tmp.dir);
    defer alloc.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io_mod.getIo(), .{});
    defer server.deinit(io_mod.getIo());

    const bytes = try alloc.alloc(u8, 8 * 1024 * 1024);
    defer alloc.free(bytes);
    @memset(bytes, 'x');
    const started = std.Io.Timestamp.now(io_mod.getIo(), .awake);
    try std.testing.expectError(error.DeliveryTimedOut, sendRecordWithDeadline(socket_path, bytes));
    const elapsed_ms = elapsedAwakeMillis(started);
    try std.testing.expect(elapsed_ms >= 100);
    try std.testing.expect(elapsed_ms < 2_000);
}

test "ADE delivery remains bounded when the receiver closes immediately" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_path = try testUnixSocketPath(alloc, tmp.dir);
    defer alloc.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io_mod.getIo(), .{});
    defer server.deinit(io_mod.getIo());

    const CloseOnAccept = struct {
        fn run(listener: *std.Io.net.Server) void {
            var stream = listener.accept(io_mod.getIo()) catch return;
            stream.close(io_mod.getIo());
        }
    };
    const receiver = try std.Thread.spawn(.{}, CloseOnAccept.run, .{&server});
    defer receiver.join();
    const bytes = try alloc.alloc(u8, 8 * 1024 * 1024);
    defer alloc.free(bytes);
    @memset(bytes, 'x');
    const started = std.Io.Timestamp.now(io_mod.getIo(), .awake);
    var delivery_failed = false;
    sendRecordWithDeadline(socket_path, bytes) catch |err| {
        delivery_failed = true;
        try std.testing.expect(err == error.WriteFailed or err == error.DeliveryTimedOut);
    };
    try std.testing.expect(delivery_failed);
    try std.testing.expect(elapsedAwakeMillis(started) < 2_000);
}

test "ADE client shutdown stays bounded with a non-reading listener" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_path = try testUnixSocketPath(alloc, tmp.dir);
    defer alloc.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io_mod.getIo(), .{});
    defer server.deinit(io_mod.getIo());

    var lifecycle = lifecycle_state.Reducer{};
    lifecycle.init(alloc);
    defer lifecycle.deinit();
    var client: Client = .{};
    try client.init(alloc, socket_path, "instance-5", "/tmp/workspace", "main-session", &lifecycle);
    errdefer client.deinit();
    const arguments = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(arguments);
    @memset(arguments, 'x');
    client.reportPreToolUse(.{
        .invocation = .{
            .scope = .{
                .kind = .interactive,
                .workspace_root = "/tmp/workspace",
                .session_id = "main-session",
            },
            .turn_id = 45,
        },
        .step_index = 1,
        .call_id = "call-1",
        .tool_name = "terminal",
        .arguments_json = arguments,
    });
    io_mod.sleep(20 * std.time.ns_per_ms);

    const started = std.Io.Timestamp.now(io_mod.getIo(), .awake);
    client.deinit();
    try std.testing.expect(elapsedAwakeMillis(started) < 2_000);
}

test "ADE feed resolves subagent attention with the child's own working snapshot" {
    const alloc = std.testing.allocator;
    var lifecycle = lifecycle_state.Reducer{};
    lifecycle.init(alloc);
    defer lifecycle.deinit();
    var client = Client{
        .enabled = true,
        .alloc = alloc,
        .socket_path = try alloc.dupe(u8, "/tmp/unused-ade.sock"),
        .instance_id = try alloc.dupe(u8, "instance-9"),
        .workspace_root = try alloc.dupe(u8, "/tmp/workspace"),
        .main_session_id = try alloc.dupe(u8, "main-session"),
        .lifecycle = &lifecycle,
    };
    defer client.deinit();

    const child = lifecycle_state.Agent{ .subagent_session = "child-session" };
    _ = lifecycle.transition(child, .turn_started, null);
    _ = lifecycle.transition(child, .attention_required, .permission);
    _ = lifecycle.transition(child, .attention_resolved, .permission);
    client.reportAttentionResolved(.{
        .invocation = .{
            .scope = .{
                .kind = .subagent,
                .workspace_root = "/tmp/workspace",
                .session_id = "child-session",
                .subagent_id = 4,
            },
            .turn_id = null,
        },
        .kind = .permission,
    });

    try std.testing.expectEqual(@as(usize, 1), client.queue_len);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        client.queue[0].?.bytes,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "AttentionResolved",
        parsed.value.object.get("event").?.string,
    );
    const context = parsed.value.object.get("context").?.object;
    try std.testing.expectEqualStrings("subagent", context.get("agent_role").?.string);
    try std.testing.expectEqualStrings("child-session", context.get("session_id").?.string);
    try std.testing.expectEqualStrings("main-session", context.get("parent_session_id").?.string);
    try std.testing.expectEqualStrings("working", context.get("agent_state").?.string);
    try std.testing.expect(context.get("attention_kind").? == .null);
    try std.testing.expectEqualStrings(
        "permission",
        parsed.value.object.get("payload").?.object.get("kind").?.string,
    );
}

test "ADE feed carries each agent's own snapshot rather than the main agent's" {
    const alloc = std.testing.allocator;
    var lifecycle = lifecycle_state.Reducer{};
    lifecycle.init(alloc);
    defer lifecycle.deinit();
    var client = Client{
        .enabled = true,
        .alloc = alloc,
        .socket_path = try alloc.dupe(u8, "/tmp/unused-ade.sock"),
        .instance_id = try alloc.dupe(u8, "instance-9"),
        .workspace_root = try alloc.dupe(u8, "/tmp/workspace"),
        .main_session_id = try alloc.dupe(u8, "main-session"),
        .lifecycle = &lifecycle,
    };
    defer client.deinit();

    // Three agents in three different states at the same instant.
    _ = lifecycle.transition(.main, .prompt_queued, null);
    _ = lifecycle.transition(
        .{ .subagent_session = "child-blocked" },
        .attention_required,
        .question,
    );
    _ = lifecycle.transition(.{ .subagent_session = "child-working" }, .turn_started, null);

    client.reportTurnStarted(.{
        .scope = .{
            .kind = .subagent,
            .workspace_root = "/tmp/workspace",
            .session_id = "child-blocked",
            .subagent_id = 1,
        },
        .turn_id = 7,
    });
    client.reportTurnStarted(.{
        .scope = .{
            .kind = .subagent,
            .workspace_root = "/tmp/workspace",
            .session_id = "child-working",
            .subagent_id = 2,
        },
        .turn_id = 8,
    });
    client.reportPromptQueued();

    try std.testing.expectEqual(@as(usize, 3), client.queue_len);
    const Expected = struct {
        session_id: ?[]const u8,
        role: []const u8,
        agent_state: []const u8,
        attention_kind: ?[]const u8,
    };
    const expected = [_]Expected{
        .{
            .session_id = "child-blocked",
            .role = "subagent",
            .agent_state = "blocked",
            .attention_kind = "question",
        },
        .{
            .session_id = "child-working",
            .role = "subagent",
            .agent_state = "working",
            .attention_kind = null,
        },
        .{
            .session_id = "main-session",
            .role = "main",
            .agent_state = "working",
            .attention_kind = null,
        },
    };
    for (expected, 0..) |want, index| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            alloc,
            client.queue[index].?.bytes,
            .{},
        );
        defer parsed.deinit();
        const context = parsed.value.object.get("context").?.object;
        try std.testing.expectEqualStrings(want.role, context.get("agent_role").?.string);
        try std.testing.expectEqualStrings(
            want.session_id.?,
            context.get("session_id").?.string,
        );
        try std.testing.expectEqualStrings(
            want.agent_state,
            context.get("agent_state").?.string,
        );
        if (want.attention_kind) |kind| {
            try std.testing.expectEqualStrings(kind, context.get("attention_kind").?.string);
        } else {
            try std.testing.expect(context.get("attention_kind").? == .null);
        }
    }
}

test "ADE sequence advances through record_too_large and queue_full drops" {
    const alloc = std.testing.allocator;
    var client = Client{
        .enabled = true,
        .alloc = alloc,
        .socket_path = try alloc.dupe(u8, "/tmp/unused-ade.sock"),
        .instance_id = try alloc.dupe(u8, "instance-9"),
        .workspace_root = try alloc.dupe(u8, "/tmp/workspace"),
        .main_session_id = try alloc.dupe(u8, "main-session"),
    };
    defer client.deinit();

    const oversized = try alloc.alloc(u8, max_record_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');

    // Sequence 1 is consumed by a record rejected before serialization.
    client.reportPreToolUse(.{
        .invocation = .{
            .scope = .{
                .kind = .interactive,
                .workspace_root = "/tmp/workspace",
                .session_id = "main-session",
            },
            .turn_id = 3,
        },
        .step_index = 1,
        .call_id = "call-1",
        .tool_name = "terminal",
        .arguments_json = oversized,
    });
    try std.testing.expectEqual(@as(usize, 0), client.queue_len);

    // The next admitted record therefore starts at 2: the consumer sees a
    // gap and knows a record was lost rather than never attempted.
    client.reportPromptQueued();
    try std.testing.expectEqual(@as(usize, 1), client.queue_len);
    try std.testing.expectEqual(@as(u64, 2), client.queue[0].?.sequence);

    // Fill the queue to its record bound, then overflow it once. Sequences
    // 2 through 129 are admitted, so the next attempt is 130.
    while (client.queue_len < max_queued_records) client.reportPromptQueued();
    try std.testing.expectEqual(@as(usize, max_queued_records), client.queue_len);
    try std.testing.expectEqual(@as(u64, 129), client.queue[client.queue_len - 1].?.sequence);
    try std.testing.expectEqual(@as(u64, 130), client.next_sequence);
    client.reportPromptQueued();
    try std.testing.expectEqual(@as(usize, max_queued_records), client.queue_len);
    try std.testing.expectEqual(@as(u64, 131), client.next_sequence);

    // Draining the backlog lets the next record show the queue_full gap on
    // the wire: 129 was queued, 130 was dropped, 131 is the next admission.
    client.mutex.lockUncancelable(io_mod.getIo());
    client.clearQueueLocked(alloc);
    client.mutex.unlock(io_mod.getIo());
    client.reportPromptQueued();
    try std.testing.expectEqual(@as(usize, 1), client.queue_len);
    try std.testing.expectEqual(@as(u64, 131), client.queue[client.queue_head].?.sequence);
}

test "ADE feed refuses tool arguments that would break record framing" {
    // Every case here is bytes the emitter was handed, not bytes it built.
    // The guard fx relies on upstream defaults to `valid` and the
    // Responses path never sets it, so the emitter cannot assume a caller
    // classified anything.
    const unframable = [_][]const u8{
        // A raw newline inside a string is the framing killer: it ends the
        // record early and leaves the remainder as a second, garbage line.
        "{\"command\":\"printf hi\nrm -rf /\"}",
        // Other raw control bytes are equally invalid JSON in a string.
        "{\"command\":\"a\tb\"}",
        "{\"command\":\"a\x00b\"}",
        // Unbalanced or mismatched structure swallows the enclosing record.
        "{\"a\":1",
        "{\"a\":1}}",
        "{\"a\":[1,2}",
        "[1,2)]",
        // An unterminated string runs into the envelope that follows.
        "{\"a\":\"unterminated}",
        // A trailing escape consumes the closing quote.
        "{\"a\":\"trailing\\",
        // Empty bytes would have emitted nothing at all, leaving the
        // record's `arguments` value missing entirely.
        "",
        "   ",
    };

    for (unframable) |arguments_json| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try writeRecord(std.testing.allocator, &output.writer, 3, "pane-1", .{ .pre_tool_use = .{
            .step_index = 1,
            .call_id = "call-1",
            .tool_name = "terminal",
            .arguments_json = arguments_json,
        } }, .{
            .agent_role = .main,
            .workspace_root = "/tmp/workspace",
            .session_id = "main-session",
            .turn_id = 5,
        });

        // One record, one line, and still decodable: the bad arguments cost
        // themselves rather than the whole record.
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "\n"));
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            output.written(),
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectEqualStrings("PreToolUse", parsed.value.object.get("event").?.string);
        const payload = parsed.value.object.get("payload").?.object;
        try std.testing.expectEqualStrings("terminal", payload.get("tool_name").?.string);
        try std.testing.expectEqual(@as(usize, 0), payload.get("arguments").?.object.count());
    }

    // Sound arguments still pass through, including escaped control bytes,
    // nesting, and the whitespace the compactor removes.
    const framable = [_][]const u8{
        "{\"command\":\"printf hi\\nrm\"}",
        "{ \"a\" : [ 1 , { \"b\" : \"c\" } ] }",
        "{\"a\":\"brace } and bracket ] inside a string\"}",
        "{\"a\":\"trailing backslash \\\\\"}",
    };
    for (framable) |arguments_json| {
        try std.testing.expect(compactJsonIsAdmissible(std.testing.allocator, arguments_json));
    }

    // Deep but sound nesting is admitted; the emitter declines what it
    // cannot prove, not what is merely large.
    var deep: [130]u8 = undefined;
    @memset(deep[0..65], '[');
    @memset(deep[65..130], ']');
    try std.testing.expect(compactJsonIsAdmissible(std.testing.allocator, &deep));
}
