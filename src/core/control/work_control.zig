const std = @import("std");
const io_mod = @import("../shared/io.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

pub const socket_path_env = "FX_WORK_CONTROL_SOCKET_PATH";
pub const instance_id_env = "FX_WORK_CONTROL_INSTANCE_ID";
pub const token_env = "FX_WORK_CONTROL_TOKEN";

pub const max_request_frame_bytes: usize = 8 * 1024 * 1024;
pub const max_external_text_bytes: usize = 1024 * 1024;
pub const max_snapshot_entries: usize = 256;
pub const max_snapshot_text_bytes: usize = 1024 * 1024;
pub const max_response_frame_bytes: usize = 8 * 1024 * 1024;

const peer_io_timeout_ms: i64 = 1_000;
const application_wait_timeout_ms: i64 = 2_000;
const listener_poll_ms: i32 = 25;
const application_poll_ns: u64 = 2 * std.time.ns_per_ms;

pub const Method = enum {
    snapshot,
    queue,
    steer,
    interrupt,
    update,
    delete,
    resume_queue,
};

pub const Request = struct {
    request_id: []u8,
    method: Method,
    text: ?[]u8 = null,
    turn_id: ?u64 = null,

    pub fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        alloc.free(self.request_id);
        if (self.text) |text| alloc.free(text);
        self.* = undefined;
    }
};

const PendingState = enum(u8) {
    queued,
    processing,
    complete,
    cancelled,
};

pub const Pending = struct {
    request: Request,
    state: std.atomic.Value(PendingState) = .init(.queued),
    response: ?[]u8 = null,
};

pub const Endpoint = struct {
    alloc: std.mem.Allocator = std.heap.c_allocator,
    socket_path: ?[]u8 = null,
    instance_id: ?[]u8 = null,
    token: ?[]u8 = null,
    server: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    pending_mutex: std.Io.Mutex = .init,
    pending: ?*Pending = null,
    bound: bool = false,

    pub fn configured(self: *const Endpoint) bool {
        return self.server != null;
    }

    pub fn instanceId(self: *const Endpoint) []const u8 {
        return self.instance_id orelse "";
    }

    /// Reads the opt-in environment as one all-or-none authority tuple and
    /// binds immediately. The listener thread starts only after App.init has
    /// returned and the final Endpoint address is stable.
    pub fn configureFromEnvironment(self: *Endpoint) !void {
        const socket_path = io_mod.getenv(socket_path_env);
        const instance_id = io_mod.getenv(instance_id_env);
        const token = io_mod.getenv(token_env);
        if (socket_path == null and instance_id == null and token == null) return;
        if (socket_path == null or instance_id == null or token == null or
            socket_path.?.len == 0 or instance_id.?.len == 0 or token.?.len == 0)
        {
            return error.IncompleteWorkControlConfiguration;
        }
        if (!std.fs.path.isAbsolute(socket_path.?) or
            instance_id.?.len > 256 or token.?.len > 4096)
        {
            return error.InvalidWorkControlConfiguration;
        }

        self.socket_path = try self.alloc.dupe(u8, socket_path.?);
        errdefer {
            self.alloc.free(self.socket_path.?);
            self.socket_path = null;
        }
        self.instance_id = try self.alloc.dupe(u8, instance_id.?);
        errdefer {
            self.alloc.free(self.instance_id.?);
            self.instance_id = null;
        }
        self.token = try self.alloc.dupe(u8, token.?);
        errdefer {
            self.alloc.free(self.token.?);
            self.token = null;
        }

        const address = std.Io.net.UnixAddress.init(self.socket_path.?) catch
            return error.InvalidWorkControlSocketPath;
        self.server = address.listen(io_mod.getIo(), .{}) catch
            return error.WorkControlBindFailed;
        self.bound = true;
        errdefer self.closeBoundEndpoint();
        try setPrivateSocketMode(self.alloc, self.socket_path.?);
        try verifyPrivateSocket(self.socket_path.?);
    }

    pub fn start(self: *Endpoint) !void {
        if (!self.configured() or self.thread != null) return;
        self.stopping.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, listenerMain, .{self});
    }

    pub fn takePending(self: *Endpoint) ?*Pending {
        if (!self.configured()) return null;
        const zio = io_mod.getIo();
        self.pending_mutex.lockUncancelable(zio);
        defer self.pending_mutex.unlock(zio);
        const pending = self.pending orelse return null;
        if (pending.state.cmpxchgStrong(
            .queued,
            .processing,
            .acq_rel,
            .acquire,
        ) != null) return null;
        return pending;
    }

    /// Takes ownership of `response`, which must come from Endpoint.alloc.
    pub fn complete(self: *Endpoint, pending: *Pending, response: []u8) void {
        _ = self;
        std.debug.assert(pending.state.load(.acquire) == .processing);
        pending.response = response;
        pending.state.store(.complete, .release);
    }

    pub fn deinit(self: *Endpoint) void {
        self.stopping.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.closeBoundEndpoint();
        if (self.socket_path) |path| self.alloc.free(path);
        if (self.instance_id) |identity| self.alloc.free(identity);
        if (self.token) |token| {
            @memset(token, 0);
            self.alloc.free(token);
        }
        self.socket_path = null;
        self.instance_id = null;
        self.token = null;
    }

    fn closeBoundEndpoint(self: *Endpoint) void {
        if (self.server) |*server| server.deinit(io_mod.getIo());
        self.server = null;
        if (self.bound) {
            std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), self.socket_path.?) catch {};
        }
        self.bound = false;
    }

    fn listenerMain(self: *Endpoint) void {
        self.listenerLoop() catch {};
    }

    fn listenerLoop(self: *Endpoint) !void {
        while (!self.stopping.load(.acquire)) {
            if (!try listenerReady(self.server.?.socket.handle)) continue;
            if (self.stopping.load(.acquire)) break;
            var stream = self.server.?.accept(io_mod.getIo()) catch |err| switch (err) {
                error.ConnectionAborted, error.WouldBlock => continue,
                error.SocketNotListening => return,
                else => return err,
            };
            defer stream.close(io_mod.getIo());
            self.servePeer(&stream) catch {};
        }
    }

    fn servePeer(self: *Endpoint, stream: *std.Io.net.Stream) !void {
        const frame = readFrame(self.alloc, stream.socket) catch |err| {
            const response = try encodeError(
                self.alloc,
                self.instanceId(),
                null,
                protocolErrorCode(err),
                protocolErrorMessage(err),
            );
            defer self.alloc.free(response);
            return writeFrame(stream.socket.handle, response);
        };
        defer self.alloc.free(frame);

        var request = decodeAuthenticatedRequest(
            self.alloc,
            frame,
            self.instanceId(),
            self.token.?,
        ) catch |err| {
            const request_id = requestIdBestEffort(self.alloc, frame);
            defer if (request_id) |owned| self.alloc.free(owned);
            const response = try encodeError(
                self.alloc,
                self.instanceId(),
                request_id,
                protocolErrorCode(err),
                protocolErrorMessage(err),
            );
            defer self.alloc.free(response);
            return writeFrame(stream.socket.handle, response);
        };
        var request_owned = true;
        defer if (request_owned) request.deinit(self.alloc);

        const pending = try self.alloc.create(Pending);
        pending.* = .{ .request = request };
        request_owned = false;
        var pending_owned = true;
        defer if (pending_owned) {
            pending.request.deinit(self.alloc);
            if (pending.response) |response| self.alloc.free(response);
            self.alloc.destroy(pending);
        };

        const zio = io_mod.getIo();
        self.pending_mutex.lockUncancelable(zio);
        if (self.pending != null) {
            self.pending_mutex.unlock(zio);
            const response = try encodeError(
                self.alloc,
                self.instanceId(),
                pending.request.request_id,
                "busy",
                "another work-control request is pending",
            );
            defer self.alloc.free(response);
            return writeFrame(stream.socket.handle, response);
        }
        self.pending = pending;
        self.pending_mutex.unlock(zio);

        const started = io_mod.milliTimestamp();
        while (true) {
            switch (pending.state.load(.acquire)) {
                .complete => break,
                .cancelled => return,
                .queued => {
                    if (self.stopping.load(.acquire) or
                        io_mod.milliTimestamp() - started >= application_wait_timeout_ms)
                    {
                        if (pending.state.cmpxchgStrong(
                            .queued,
                            .cancelled,
                            .acq_rel,
                            .acquire,
                        ) == null) {
                            self.clearPending(pending);
                            const response = try encodeError(
                                self.alloc,
                                self.instanceId(),
                                pending.request.request_id,
                                if (self.stopping.load(.acquire)) "shutting_down" else "application_timeout",
                                if (self.stopping.load(.acquire)) "Fx is shutting down" else "Fx did not apply the request before its deadline",
                            );
                            defer self.alloc.free(response);
                            return writeFrame(stream.socket.handle, response);
                        }
                    }
                },
                .processing => {},
            }
            io_mod.sleep(application_poll_ns);
        }

        self.clearPending(pending);
        const response = pending.response orelse return error.WorkControlResponseMissing;
        pending.response = null;
        pending_owned = false;
        defer {
            pending.request.deinit(self.alloc);
            self.alloc.destroy(pending);
            self.alloc.free(response);
        }
        try writeFrame(stream.socket.handle, response);
    }

    fn clearPending(self: *Endpoint, pending: *Pending) void {
        const zio = io_mod.getIo();
        self.pending_mutex.lockUncancelable(zio);
        if (self.pending == pending) self.pending = null;
        self.pending_mutex.unlock(zio);
    }
};

pub fn encodeSnapshotResponse(
    alloc: std.mem.Allocator,
    instance_id: []const u8,
    request_id: []const u8,
    snapshot: worker_runtime.WorkSnapshot,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeResponsePrefix(&out.writer, instance_id, request_id, true);
    try out.writer.writeAll("\"result\":{\"snapshot\":");
    try writeSnapshot(&out.writer, snapshot);
    try out.writer.writeAll("}}");
    return finishResponse(&out);
}

pub fn encodeAdmissionResponse(
    alloc: std.mem.Allocator,
    instance_id: []const u8,
    request_id: []const u8,
    admission: worker_runtime.PromptAdmissionResult,
    snapshot: worker_runtime.WorkSnapshot,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeResponsePrefix(&out.writer, instance_id, request_id, true);
    try out.writer.writeAll("\"result\":{\"turn_id\":");
    try writeTurnId(&out.writer, admission.turn_id);
    try out.writer.writeAll(",\"disposition\":");
    try std.json.Stringify.value(@tagName(admission.disposition), .{}, &out.writer);
    try out.writer.writeAll(",\"snapshot\":");
    try writeSnapshot(&out.writer, snapshot);
    try out.writer.writeAll("}}");
    return finishResponse(&out);
}

pub fn encodeMutationResponse(
    alloc: std.mem.Allocator,
    instance_id: []const u8,
    request_id: []const u8,
    snapshot: worker_runtime.WorkSnapshot,
) ![]u8 {
    return encodeSnapshotResponse(alloc, instance_id, request_id, snapshot);
}

pub fn encodeError(
    alloc: std.mem.Allocator,
    instance_id: []const u8,
    request_id: ?[]const u8,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":1,\"request_id\":");
    if (request_id) |value| try std.json.Stringify.value(value, .{}, &out.writer) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"instance_id\":");
    try std.json.Stringify.value(instance_id, .{}, &out.writer);
    try out.writer.writeAll(",\"ok\":false,\"error\":{\"code\":");
    try std.json.Stringify.value(code, .{}, &out.writer);
    try out.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return finishResponse(&out);
}

fn writeResponsePrefix(
    writer: *std.Io.Writer,
    instance_id: []const u8,
    request_id: []const u8,
    ok: bool,
) !void {
    try writer.writeAll("{\"schema\":1,\"request_id\":");
    try std.json.Stringify.value(request_id, .{}, writer);
    try writer.writeAll(",\"instance_id\":");
    try std.json.Stringify.value(instance_id, .{}, writer);
    try writer.print(",\"ok\":{s},", .{if (ok) "true" else "false"});
}

fn writeSnapshot(writer: *std.Io.Writer, snapshot: worker_runtime.WorkSnapshot) !void {
    try writer.writeByte('{');
    try writeSnapshotFields(writer, snapshot);
    try writer.writeByte('}');
}

/// The snapshot's fields without their enclosing braces, so a surface that
/// must report more than work control does (ACP adds the parent's children)
/// still reports the queue in exactly these bytes.
pub fn writeSnapshotFields(writer: *std.Io.Writer, snapshot: worker_runtime.WorkSnapshot) !void {
    try writer.writeAll("\"active_turn_id\":");
    if (snapshot.active_turn_id) |turn_id| try writeTurnId(writer, turn_id) else try writer.writeAll("null");
    try writer.print(",\"queue_paused\":{s},\"queue\":[", .{
        if (snapshot.queue_paused) "true" else "false",
    });
    for (snapshot.entries, 0..) |entry, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"turn_id\":");
        try writeTurnId(writer, entry.turn_id);
        try writer.writeAll(",\"kind\":");
        try std.json.Stringify.value(@tagName(entry.kind), .{}, writer);
        try writer.writeAll(",\"text\":");
        try std.json.Stringify.value(entry.text, .{}, writer);
        try writer.print(",\"has_images\":{s},\"has_skill_bindings\":{s},\"has_review_draft\":{s}}}", .{
            if (entry.has_images) "true" else "false",
            if (entry.has_skill_bindings) "true" else "false",
            if (entry.has_review_draft) "true" else "false",
        });
    }
    try writer.writeByte(']');
}

fn writeTurnId(writer: *std.Io.Writer, turn_id: u64) !void {
    var buffer: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&buffer, "{d}", .{turn_id});
    try std.json.Stringify.value(value, .{}, writer);
}

fn finishResponse(out: *std.Io.Writer.Allocating) ![]u8 {
    if (out.written().len > max_response_frame_bytes) return error.WorkControlResponseTooLarge;
    return out.toOwnedSlice();
}

fn decodeAuthenticatedRequest(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    expected_instance_id: []const u8,
    expected_token: []const u8,
) !Request {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidWorkControlJson,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidWorkControlRequest;
    const root = parsed.value.object;
    if (root.count() != 6) return error.InvalidWorkControlRequest;
    const schema = root.get("schema") orelse return error.InvalidWorkControlRequest;
    if (schema != .integer or schema.integer != 1) return error.UnsupportedWorkControlSchema;
    const request_id_value = try requiredString(root, "request_id", 256);
    const instance_value = try requiredString(root, "instance_id", 256);
    const token_value = try requiredString(root, "token", 4096);
    const method_value = try requiredString(root, "method", 64);
    const params_value = root.get("params") orelse return error.InvalidWorkControlRequest;
    if (params_value != .object) return error.InvalidWorkControlRequest;
    if (!std.mem.eql(u8, instance_value, expected_instance_id)) return error.WorkControlInstanceMismatch;
    if (!timingSafeEqual(token_value, expected_token)) return error.WorkControlUnauthorized;

    const method = methodFromWire(method_value) orelse return error.UnknownWorkControlMethod;
    const params = params_value.object;
    var text: ?[]u8 = null;
    errdefer if (text) |owned| alloc.free(owned);
    var turn_id: ?u64 = null;
    switch (method) {
        .snapshot, .interrupt, .resume_queue => if (params.count() != 0)
            return error.InvalidWorkControlParams,
        .queue, .steer => {
            if (params.count() != 1) return error.InvalidWorkControlParams;
            const value = try requiredParamString(params, "text", max_external_text_bytes);
            if (value.len == 0) return error.EmptyWorkControlText;
            text = try alloc.dupe(u8, value);
        },
        .update => {
            if (params.count() != 2) return error.InvalidWorkControlParams;
            turn_id = try requiredTurnId(params, "turn_id");
            const value = try requiredParamString(params, "text", max_external_text_bytes);
            if (value.len == 0) return error.EmptyWorkControlText;
            text = try alloc.dupe(u8, value);
        },
        .delete => {
            if (params.count() != 1) return error.InvalidWorkControlParams;
            turn_id = try requiredTurnId(params, "turn_id");
        },
    }

    return .{
        .request_id = try alloc.dupe(u8, request_id_value),
        .method = method,
        .text = text,
        .turn_id = turn_id,
    };
}

fn methodFromWire(value: []const u8) ?Method {
    const pairs = .{
        .{ "work.snapshot", Method.snapshot },
        .{ "work.queue", Method.queue },
        .{ "work.steer", Method.steer },
        .{ "work.interrupt", Method.interrupt },
        .{ "queue.update", Method.update },
        .{ "queue.delete", Method.delete },
        .{ "queue.resume", Method.resume_queue },
    };
    inline for (pairs) |pair| if (std.mem.eql(u8, value, pair[0])) return pair[1];
    return null;
}

fn requiredString(
    object: std.json.ObjectMap,
    name: []const u8,
    max_len: usize,
) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidWorkControlRequest;
    if (value != .string or value.string.len == 0 or value.string.len > max_len or
        !std.unicode.utf8ValidateSlice(value.string))
    {
        return error.InvalidWorkControlRequest;
    }
    return value.string;
}

fn requiredTurnId(object: std.json.ObjectMap, name: []const u8) !u64 {
    const value = try requiredParamString(object, name, 32);
    const turn_id = std.fmt.parseInt(u64, value, 10) catch
        return error.InvalidWorkControlParams;
    if (turn_id == 0) return error.InvalidWorkControlParams;
    return turn_id;
}

fn requiredParamString(
    object: std.json.ObjectMap,
    name: []const u8,
    max_len: usize,
) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidWorkControlParams;
    if (value != .string or value.string.len == 0 or value.string.len > max_len or
        !std.unicode.utf8ValidateSlice(value.string))
    {
        return error.InvalidWorkControlParams;
    }
    return value.string;
}

fn timingSafeEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var difference: u8 = 0;
    for (left, right) |a, b| difference |= a ^ b;
    return difference == 0;
}

fn requestIdBestEffort(alloc: std.mem.Allocator, bytes: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("request_id") orelse return null;
    if (value != .string or value.string.len == 0 or value.string.len > 256) return null;
    return alloc.dupe(u8, value.string) catch null;
}

fn protocolErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.WorkControlUnauthorized => "unauthorized",
        error.WorkControlInstanceMismatch => "instance_mismatch",
        error.UnsupportedWorkControlSchema => "unsupported_schema",
        error.UnknownWorkControlMethod => "unknown_method",
        error.EmptyWorkControlText => "empty_text",
        error.WorkControlFrameTooLarge => "frame_too_large",
        error.WorkControlReadTimeout => "read_timeout",
        error.InvalidWorkControlParams => "invalid_params",
        else => "invalid_request",
    };
}

fn protocolErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.WorkControlUnauthorized => "invalid work-control bearer token",
        error.WorkControlInstanceMismatch => "request targets another Fx instance",
        error.UnsupportedWorkControlSchema => "unsupported work-control schema",
        error.UnknownWorkControlMethod => "unknown work-control method",
        error.EmptyWorkControlText => "work text must not be empty",
        error.WorkControlFrameTooLarge => "work-control frame exceeds its limit",
        error.WorkControlReadTimeout => "work-control request read timed out",
        error.InvalidWorkControlParams => "invalid work-control parameters",
        else => "invalid work-control request",
    };
}

fn readFrame(alloc: std.mem.Allocator, socket: std.Io.net.Socket) ![]u8 {
    const deadline = io_mod.milliTimestamp() + peer_io_timeout_ms;
    var header: [4]u8 = undefined;
    try receiveExact(socket, &header, deadline);
    const frame_len: usize = std.mem.readInt(u32, &header, .big);
    if (frame_len == 0 or frame_len > max_request_frame_bytes) {
        return error.WorkControlFrameTooLarge;
    }
    const frame = try alloc.alloc(u8, frame_len);
    errdefer alloc.free(frame);
    try receiveExact(socket, frame, deadline);
    return frame;
}

fn receiveExact(socket: std.Io.net.Socket, destination: []u8, deadline_ms: i64) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const remaining = deadline_ms - io_mod.milliTimestamp();
        if (remaining <= 0) return error.WorkControlReadTimeout;
        const incoming = socket.receiveTimeout(
            io_mod.getIo(),
            destination[offset..],
            .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(@intCast(@min(remaining, 100))),
            } },
        ) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        if (incoming.data.len == 0) return error.EndOfStream;
        offset += incoming.data.len;
    }
}

fn writeFrame(fd: std.posix.fd_t, payload: []const u8) !void {
    if (payload.len > max_response_frame_bytes) return error.WorkControlResponseTooLarge;
    try setNonblocking(fd);
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
    const deadline = io_mod.milliTimestamp() + peer_io_timeout_ms;
    try sendAll(fd, &header, deadline);
    try sendAll(fd, payload, deadline);
}

fn sendAll(fd: std.posix.fd_t, bytes: []const u8, deadline_ms: i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (io_mod.milliTimestamp() >= deadline_ms) return error.WorkControlWriteTimeout;
        const rc = std.c.send(fd, bytes[offset..].ptr, bytes.len - offset, std.posix.MSG.NOSIGNAL);
        switch (std.c.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WorkControlWriteFailed;
                offset += @intCast(rc);
            },
            .INTR => continue,
            .AGAIN => {
                var poll_fds = [_]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = try std.posix.poll(&poll_fds, listener_poll_ms);
            },
            else => return error.WorkControlWriteFailed,
        }
    }
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const current = while (true) {
        const rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return error.WorkControlSocketOptionFailed,
        }
    };
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    while (true) switch (std.posix.errno(std.posix.system.fcntl(
        fd,
        std.posix.F.SETFL,
        current | nonblock,
    ))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.WorkControlSocketOptionFailed,
    };
}

fn listenerReady(fd: std.posix.fd_t) !bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = try std.posix.poll(&poll_fds, listener_poll_ms);
    return (poll_fds[0].revents & std.posix.POLL.IN) != 0;
}

fn setPrivateSocketMode(alloc: std.mem.Allocator, path: []const u8) !void {
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    if (std.c.chmod(path_z.ptr, 0o600) != 0) return error.WorkControlPrivateModeFailed;
}

fn verifyPrivateSocket(path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        path,
        .{ .follow_symlinks = false },
    );
    if (stat.kind != .unix_domain_socket or stat.permissions.toMode() & 0o777 != 0o600) {
        return error.WorkControlPrivateModeFailed;
    }
}

test "strict authenticated request decoding preserves opaque turn ids" {
    const alloc = std.testing.allocator;
    var request = try decodeAuthenticatedRequest(
        alloc,
        "{\"schema\":1,\"request_id\":\"r1\",\"instance_id\":\"i1\",\"token\":\"secret\",\"method\":\"queue.update\",\"params\":{\"turn_id\":\"18446744073709551615\",\"text\":\"new work\"}}",
        "i1",
        "secret",
    );
    defer request.deinit(alloc);
    try std.testing.expectEqual(Method.update, request.method);
    try std.testing.expectEqual(std.math.maxInt(u64), request.turn_id.?);
    try std.testing.expectEqualStrings("new work", request.text.?);
}

test "request decoding rejects partial authority and extra parameters" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.WorkControlUnauthorized,
        decodeAuthenticatedRequest(
            alloc,
            "{\"schema\":1,\"request_id\":\"r1\",\"instance_id\":\"i1\",\"token\":\"wrong\",\"method\":\"work.snapshot\",\"params\":{}}",
            "i1",
            "secret",
        ),
    );
    try std.testing.expectError(
        error.InvalidWorkControlParams,
        decodeAuthenticatedRequest(
            alloc,
            "{\"schema\":1,\"request_id\":\"r1\",\"instance_id\":\"i1\",\"token\":\"secret\",\"method\":\"work.snapshot\",\"params\":{\"extra\":true}}",
            "i1",
            "secret",
        ),
    );
}

test "success responses carry correlated authoritative snapshots" {
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(worker_runtime.WorkQueueEntry, 1);
    entries[0] = .{
        .turn_id = std.math.maxInt(u64),
        .kind = .steering,
        .text = try alloc.dupe(u8, "next\nwork"),
        .has_images = false,
        .has_skill_bindings = false,
        .has_review_draft = false,
    };
    const snapshot: worker_runtime.WorkSnapshot = .{
        .active_turn_id = 41,
        .queue_paused = true,
        .entries = entries,
    };
    defer snapshot.deinit(alloc);

    const encoded = try encodeAdmissionResponse(
        alloc,
        "instance-1",
        "request-1",
        .{ .turn_id = 42, .disposition = .steering },
        snapshot,
    );
    defer alloc.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("request-1", root.get("request_id").?.string);
    try std.testing.expectEqualStrings("instance-1", root.get("instance_id").?.string);
    const result = root.get("result").?.object;
    try std.testing.expectEqualStrings("42", result.get("turn_id").?.string);
    const work = result.get("snapshot").?.object;
    try std.testing.expectEqualStrings("41", work.get("active_turn_id").?.string);
    try std.testing.expect(work.get("queue_paused").?.bool);
    try std.testing.expectEqualStrings(
        "18446744073709551615",
        work.get("queue").?.array.items[0].object.get("turn_id").?.string,
    );
}
