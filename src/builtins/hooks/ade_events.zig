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

pub const schema_version: u8 = 1;

const delivery_deadline_ms: i64 = 250;
const max_queued_records: usize = 128;
const max_queued_bytes: usize = 8 * 1024 * 1024;
const max_record_bytes: usize = 2 * 1024 * 1024;

const Event = enum {
    fx_started,
    session_changed,
    prompt_queued,
    turn_started,
    pre_tool_use,
    stop,
    post_turn_end,
    attention_required,
    fx_stopped,

    fn wireName(self: Event) []const u8 {
        return switch (self) {
            .fx_started => "FxStarted",
            .session_changed => "SessionChanged",
            .prompt_queued => "PromptQueued",
            .turn_started => "TurnStarted",
            .pre_tool_use => "PreToolUse",
            .stop => "Stop",
            .post_turn_end => "PostTurnEnd",
            .attention_required => "AttentionRequired",
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
};

const Payload = union(Event) {
    fx_started,
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
    ) void {
        if (comptime host_target.is_wasm or builtin.os.tag == .windows) return;
        const socket_path = io_mod.getenv("FX_ADE_SOCKET_PATH");
        const instance_id = io_mod.getenv("FX_ADE_INSTANCE_ID");
        if (!shouldEnable(socket_path, instance_id)) {
            debug_trace.logf("ade_events", "disabled socket={s} instance={s}", .{
                socket_path orelse "(unset)",
                instance_id orelse "(unset)",
            });
            return;
        }

        self.init(
            alloc,
            socket_path.?,
            instance_id.?,
            workspace_root,
            main_session_id,
        ) catch |err| {
            debug_trace.logf("ade_events", "initialization failed err={s}", .{@errorName(err)});
        };
    }

    fn init(
        self: *Client,
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        instance_id: []const u8,
        workspace_root: []const u8,
        main_session_id: ?[]const u8,
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
        self.emitLocked(payload, .{
            .agent_role = role,
            .workspace_root = invocation.scope.workspace_root,
            .session_id = invocation.scope.session_id,
            .parent_session_id = if (role == .subagent) self.main_session_id else null,
            .subagent_id = invocation.scope.subagent_id,
            .turn_id = invocation.turn_id,
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
        self.emitLocked(.{ .session_changed = .{
            .previous_session_id = previous_session_id,
            .session_id = self.main_session_id,
        } }, .{
            .agent_role = .main,
            .workspace_root = workspace_root,
            .session_id = self.main_session_id,
        });
        if (previous_session_id) |session_id| alloc.free(session_id);
    }

    fn mainContext(self: *const Client, turn_id: ?u64) Context {
        return .{
            .agent_role = .main,
            .workspace_root = self.workspace_root,
            .session_id = self.main_session_id,
            .turn_id = turn_id,
        };
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
        try writeRecord(&output.writer, sequence, instance_id, payload, context);
        return output.toOwnedSlice();
    }
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn configure(
            app: *App,
            active_session_id: ?[]const u8,
        ) !void {
            app.ade_events.initFromEnv(
                app.alloc,
                app.workspace_root,
                active_session_id,
            );
            if (!app.ade_events.enabled) return;

            try app.lifecycle_runtime.registerTurnStarted(.{
                .name = "fx.ade.turn_started",
                .ctx = app,
                .run = turnStarted,
            });
            try app.lifecycle_runtime.registerPreToolUse(.{
                .name = "fx.ade.pre_tool_use",
                .ctx = app,
                .run = preToolUse,
            });
            try app.lifecycle_runtime.registerStop(.{
                .name = "fx.ade.stop",
                .ctx = app,
                .run = stop,
            });
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.ade.post_turn_end",
                .ctx = app,
                .run = postTurnEnd,
            });
        }

        pub fn reportPromptQueued(app: *App) void {
            app.ade_events.reportPromptQueued();
        }

        pub fn reportSessionChanged(app: *App, session_id: ?[]const u8) void {
            app.ade_events.reportSessionChanged(session_id);
        }

        pub fn reportAttentionRequired(
            app: *App,
            input: hooks.AttentionRequiredInput,
        ) void {
            app.ade_events.reportAttentionRequired(input);
        }

        fn turnStarted(raw: *anyopaque, input: hooks.TurnStartedInput) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            app.ade_events.reportTurnStarted(input.invocation);
        }

        fn preToolUse(raw: *anyopaque, input: hooks.PreToolUseInput) hooks.HandlerError!hooks.PreToolUseAction {
            const app: *App = @ptrCast(@alignCast(raw));
            app.ade_events.reportPreToolUse(input);
            return .continue_;
        }

        fn stop(raw: *anyopaque, input: hooks.StopInput) hooks.HandlerError!hooks.StopAction {
            const app: *App = @ptrCast(@alignCast(raw));
            app.ade_events.reportStop(input);
            return .allow;
        }

        fn postTurnEnd(raw: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            app.ade_events.reportPostTurnEnd(input);
        }
    };
}

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
    try writer.writeAll("},\"payload\":");
    try writePayload(writer, payload);
    try writer.writeAll("}\n");
}

fn writePayload(writer: *std.Io.Writer, payload: Payload) !void {
    switch (payload) {
        .fx_started, .prompt_queued, .turn_started, .fx_stopped => try writer.writeAll("{}"),
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
            try writeCompactJson(writer, value.arguments_json);
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
    }
}

fn writeCompactJson(writer: *std.Io.Writer, value: []const u8) !void {
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
    try writeRecord(&output.writer, 7, "pane-3", .turn_started, .{
        .agent_role = .main,
        .workspace_root = "/tmp/workspace",
        .session_id = "main-session",
        .turn_id = 42,
    });

    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"sequence\":7,\"event\":\"TurnStarted\"," ++
            "\"instance_id\":\"pane-3\",\"context\":{\"agent_role\":\"main\"," ++
            "\"workspace_root\":\"/tmp/workspace\",\"session_id\":\"main-session\"," ++
            "\"parent_session_id\":null,\"subagent_id\":null,\"turn_id\":42},\"payload\":{}}\n",
        output.written(),
    );
}

test "ADE feed keeps child and parent identities on subagent tool events" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRecord(&output.writer, 8, "pane-3", .{ .pre_tool_use = .{
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
    const arguments = parsed.value.object.get("payload").?.object.get("arguments").?.object;
    try std.testing.expectEqualStrings("a\"b", arguments.get("path").?.string);
}

test "ADE feed compacts tool JSON so valid whitespace cannot split NDJSON framing" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRecord(&output.writer, 9, "pane-3", .{ .pre_tool_use = .{
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
    var client = Client{
        .enabled = true,
        .alloc = alloc,
        .socket_path = try alloc.dupe(u8, "/tmp/unused-ade.sock"),
        .instance_id = try alloc.dupe(u8, "instance-4"),
        .workspace_root = try alloc.dupe(u8, "/tmp/workspace"),
        .main_session_id = try alloc.dupe(u8, "old-main"),
    };
    defer client.deinit();

    client.reportPromptQueued();
    client.reportSessionChanged("new-main");
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

    var client: Client = .{};
    try client.init(alloc, socket_path, "instance-5", "/tmp/workspace", "main-session");
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

const RecordingClient = struct {
    enabled: bool = false,
    events: [8]Event = undefined,
    roles: [8]AgentRole = undefined,
    count: usize = 0,
    configured_workspace: ?[]const u8 = null,
    configured_session: ?[]const u8 = null,
    reported_session: ?[]const u8 = null,

    fn initFromEnv(
        self: *RecordingClient,
        _: std.mem.Allocator,
        workspace_root: []const u8,
        main_session_id: ?[]const u8,
    ) void {
        self.enabled = true;
        self.configured_workspace = workspace_root;
        self.configured_session = main_session_id;
    }

    fn record(self: *RecordingClient, event: Event, invocation: hooks.Invocation) void {
        const role = roleForScope(invocation.scope.kind) orelse return;
        self.events[self.count] = event;
        self.roles[self.count] = role;
        self.count += 1;
    }

    fn reportTurnStarted(self: *RecordingClient, invocation: hooks.Invocation) void {
        self.record(.turn_started, invocation);
    }

    fn reportPromptQueued(self: *RecordingClient) void {
        self.events[self.count] = .prompt_queued;
        self.roles[self.count] = .main;
        self.count += 1;
    }

    fn reportSessionChanged(self: *RecordingClient, session_id: ?[]const u8) void {
        self.reported_session = session_id;
    }

    fn reportPreToolUse(self: *RecordingClient, input: hooks.PreToolUseInput) void {
        self.record(.pre_tool_use, input.invocation);
    }

    fn reportStop(self: *RecordingClient, input: hooks.StopInput) void {
        self.record(.stop, input.invocation);
    }

    fn reportPostTurnEnd(self: *RecordingClient, input: hooks.PostTurnEndInput) void {
        self.record(.post_turn_end, input.invocation);
    }

    fn reportAttentionRequired(self: *RecordingClient, input: hooks.AttentionRequiredInput) void {
        self.record(.attention_required, input.invocation);
    }
};

fn testInvocation(scope: hooks.ScopeKind) hooks.Invocation {
    return .{
        .scope = .{
            .kind = scope,
            .workspace_root = "/tmp/workspace",
            .session_id = if (scope == .subagent) "child-session" else "main-session",
        },
        .turn_id = 42,
    };
}

test "ADE runtime forwards main and subagent lifecycle without installing other process scopes" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8,
        lifecycle_runtime: hooks.Runtime,
        ade_events: RecordingClient = .{},
    };

    var app = TestApp{
        .alloc = std.testing.allocator,
        .workspace_root = "/tmp/workspace",
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();
    try Runtime(TestApp).configure(&app, "main-session");
    try std.testing.expectEqualStrings("/tmp/workspace", app.ade_events.configured_workspace.?);
    try std.testing.expectEqualStrings("main-session", app.ade_events.configured_session.?);
    Runtime(TestApp).reportPromptQueued(&app);
    Runtime(TestApp).reportSessionChanged(&app, "next-main-session");
    try std.testing.expectEqualStrings("next-main-session", app.ade_events.reported_session.?);

    const view = app.lifecycle_runtime.freeze();
    view.runTurnStarted(.{ .invocation = testInvocation(.interactive) });
    view.runTurnStarted(.{ .invocation = testInvocation(.subagent) });
    view.runTurnStarted(.{ .invocation = testInvocation(.ask) });
    var pre = try view.runPreToolUse(std.testing.allocator, .{
        .invocation = testInvocation(.subagent),
        .step_index = 1,
        .call_id = "call",
        .tool_name = "read_file",
        .arguments_json = "{}",
    });
    defer pre.deinit(std.testing.allocator);
    try std.testing.expect(pre == .unchanged);
    var stop_result = view.runStop(std.testing.allocator, .{
        .invocation = testInvocation(.interactive),
        .step_index = 2,
        .assistant_text = "done",
        .provider_disposition = .completed,
        .can_continue = true,
    });
    defer stop_result.deinit(std.testing.allocator);
    try std.testing.expect(stop_result == .allow);
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.subagent),
        .outcome = .completed,
    });
    Runtime(TestApp).reportAttentionRequired(&app, .{
        .invocation = testInvocation(.subagent),
        .kind = .permission,
    });
    Runtime(TestApp).reportAttentionRequired(&app, .{
        .invocation = testInvocation(.acp),
        .kind = .question,
    });

    try std.testing.expectEqual(@as(usize, 7), app.ade_events.count);
    const expected_events = [_]Event{
        .prompt_queued,
        .turn_started,
        .turn_started,
        .pre_tool_use,
        .stop,
        .post_turn_end,
        .attention_required,
    };
    const expected_roles = [_]AgentRole{
        .main,
        .main,
        .subagent,
        .subagent,
        .main,
        .subagent,
        .subagent,
    };
    try std.testing.expectEqualSlices(Event, &expected_events, app.ade_events.events[0..app.ade_events.count]);
    try std.testing.expectEqualSlices(AgentRole, &expected_roles, app.ade_events.roles[0..app.ade_events.count]);
}
