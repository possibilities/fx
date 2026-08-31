const std = @import("std");
const io_mod = @import("../shared/io.zig");
const public_protocol = @import("launch_admission_final.zig");
const launcher = @import("launch_admission_final_launcher.zig");
const child_runtime = @import("launch_admission_final_runtime.zig");

const Allocator = std.mem.Allocator;

pub const schema_id = "fx.private-launch-provider";
pub const schema_version: u16 = 1;
pub const internal_mode = "--internal-launch-provider";
pub const directory_env = "FX_INTERNAL_LAUNCH_PROVIDER_DIRECTORY";
pub const instance_id_env = "FX_INTERNAL_LAUNCH_PROVIDER_INSTANCE_ID";
pub const token_env = "FX_INTERNAL_LAUNCH_PROVIDER_TOKEN";
pub const socket_name = "provider.sock";
pub const max_frame_bytes: usize = 1024 * 1024;
pub const max_launch_controls_bytes: usize = 128 * 1024;
const peer_timeout_ms: i64 = 2_000;
const accept_timeout_ms: i32 = 5_000;

const Operation = enum {
    prepare,
    build,
    inspect,
    cancel,
    record_final,
    acknowledge_final,
};

const Request = struct {
    arena: std.heap.ArenaAllocator,
    request_id: []const u8,
    operation: Operation,
    object: std.json.ObjectMap,

    fn deinit(self: *Request) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const EndpointDirectory = struct {
    alloc: Allocator,
    parent: std.Io.Dir,
    dir: std.Io.Dir,
    name: []u8,
    path: []u8,
    identity: std.c.Stat,

    fn create(alloc: Allocator, path: []const u8) !EndpointDirectory {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidLaunchProviderConfiguration;
        const parent_path = std.fs.path.dirname(path) orelse
            return error.InvalidLaunchProviderConfiguration;
        const name = std.fs.path.basename(path);
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            return error.InvalidLaunchProviderConfiguration;
        }

        const owned_path = try alloc.dupe(u8, path);
        errdefer alloc.free(owned_path);
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        var parent = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent_path, .{
            .follow_symlinks = false,
        });
        errdefer parent.close(io_mod.getIo());
        parent.createDir(io_mod.getIo(), name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => return error.LaunchProviderDirectoryNotFresh,
            else => return err,
        };
        errdefer parent.deleteDir(io_mod.getIo(), name) catch {};
        var dir = try parent.openDir(io_mod.getIo(), name, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        errdefer dir.close(io_mod.getIo());
        try dir.setPermissions(io_mod.getIo(), .fromMode(0o700));
        const identity = try nativeStatFd(dir.handle);
        try validateEndpointDirectory(identity);

        var endpoint = EndpointDirectory{
            .alloc = alloc,
            .parent = parent,
            .dir = dir,
            .name = owned_name,
            .path = owned_path,
            .identity = identity,
        };
        try endpoint.verifyDirectoryPath();
        return endpoint;
    }

    fn deinit(self: *EndpointDirectory) void {
        self.dir.deleteFile(io_mod.getIo(), socket_name) catch {};
        self.dir.close(io_mod.getIo());
        if (self.childPathStillAnchored()) {
            self.parent.deleteDir(io_mod.getIo(), self.name) catch {};
        }
        self.parent.close(io_mod.getIo());
        self.alloc.free(self.name);
        self.alloc.free(self.path);
        self.* = undefined;
    }

    fn childPathStillAnchored(self: *EndpointDirectory) bool {
        var current = self.parent.openDir(io_mod.getIo(), self.name, .{
            .follow_symlinks = false,
        }) catch return false;
        defer current.close(io_mod.getIo());
        const current_identity = nativeStatFd(current.handle) catch return false;
        return sameFileIdentity(self.identity, current_identity);
    }

    fn verifyDirectoryPath(self: *EndpointDirectory) !void {
        var current = std.Io.Dir.openDirAbsolute(io_mod.getIo(), self.path, .{
            .follow_symlinks = false,
        }) catch return error.LaunchProviderDirectorySubstituted;
        defer current.close(io_mod.getIo());
        const current_identity = nativeStatFd(current.handle) catch
            return error.LaunchProviderDirectorySubstituted;
        if (!sameFileIdentity(self.identity, current_identity)) {
            return error.LaunchProviderDirectorySubstituted;
        }
        try validateEndpointDirectory(current_identity);
    }

    fn secureBoundSocket(self: *EndpointDirectory) !void {
        try self.verifyDirectoryPath();
        const before = nativeStatAt(self.dir.handle, socket_name) catch
            return error.LaunchProviderSocketUnsafe;
        try validateSocketIdentity(before, false);
        self.dir.setFilePermissions(
            io_mod.getIo(),
            socket_name,
            .fromMode(0o600),
            .{ .follow_symlinks = true },
        ) catch return error.LaunchProviderSocketUnsafe;
        const after = nativeStatAt(self.dir.handle, socket_name) catch
            return error.LaunchProviderSocketUnsafe;
        if (!sameFileIdentity(before, after)) return error.LaunchProviderSocketSubstituted;
        try validateSocketIdentity(after, true);
        try self.verifySocketPath(after);
    }

    fn verifyBoundSocket(self: *EndpointDirectory) !void {
        const anchored = nativeStatAt(self.dir.handle, socket_name) catch
            return error.LaunchProviderSocketSubstituted;
        try validateSocketIdentity(anchored, true);
        try self.verifySocketPath(anchored);
    }

    fn verifySocketPath(self: *EndpointDirectory, anchored: std.c.Stat) !void {
        var current = std.Io.Dir.openDirAbsolute(io_mod.getIo(), self.path, .{
            .follow_symlinks = false,
        }) catch return error.LaunchProviderDirectorySubstituted;
        defer current.close(io_mod.getIo());
        const current_identity = nativeStatFd(current.handle) catch
            return error.LaunchProviderDirectorySubstituted;
        if (!sameFileIdentity(self.identity, current_identity)) {
            return error.LaunchProviderDirectorySubstituted;
        }
        const via_path = nativeStatAt(current.handle, socket_name) catch
            return error.LaunchProviderSocketSubstituted;
        if (!sameFileIdentity(anchored, via_path)) return error.LaunchProviderSocketSubstituted;
        try validateSocketIdentity(via_path, true);
    }
};

pub fn isProviderModeRaw(args: []const [*:0]const u8) bool {
    return args.len == 2 and std.mem.eql(u8, std.mem.span(args[1]), internal_mode);
}

/// Runs one authenticated provider request. The helper owns no interactive
/// child or PTY; it exits after replying and all recovery authority remains in
/// Fx's existing launch ledger.
pub fn runOne(alloc: Allocator) !void {
    const directory = io_mod.getenv(directory_env) orelse return error.IncompleteLaunchProviderConfiguration;
    const instance_id = io_mod.getenv(instance_id_env) orelse return error.IncompleteLaunchProviderConfiguration;
    const token = io_mod.getenv(token_env) orelse return error.IncompleteLaunchProviderConfiguration;
    if (!std.fs.path.isAbsolute(directory) or instance_id.len == 0 or instance_id.len > 256 or
        token.len < 32 or token.len > 4096)
    {
        return error.InvalidLaunchProviderConfiguration;
    }

    var endpoint = try EndpointDirectory.create(alloc, directory);
    defer endpoint.deinit();
    const socket_path = try std.fs.path.join(alloc, &.{ endpoint.path, socket_name });
    defer alloc.free(socket_path);
    const address = std.Io.net.UnixAddress.init(socket_path) catch
        return error.InvalidLaunchProviderSocketPath;
    var server = address.listen(io_mod.getIo(), .{}) catch return error.LaunchProviderBindFailed;
    defer server.deinit(io_mod.getIo());
    try endpoint.secureBoundSocket();

    if (!try listenerReady(server.socket.handle, accept_timeout_ms)) return error.LaunchProviderAcceptTimeout;
    var stream = try server.accept(io_mod.getIo());
    defer stream.close(io_mod.getIo());
    try endpoint.verifyBoundSocket();
    const frame = try readFrame(alloc, stream.socket);
    defer alloc.free(frame);
    const response = handleFrame(alloc, frame, instance_id, token) catch |err|
        try encodeError(alloc, instance_id, requestIdBestEffort(alloc, frame), @errorName(err));
    defer alloc.free(response);
    try writeFrame(stream.socket.handle, response);
}

pub fn handleFrame(
    alloc: Allocator,
    frame: []const u8,
    instance_id: []const u8,
    token: []const u8,
) ![]u8 {
    var request = try decodeRequest(alloc, frame, instance_id, token);
    defer request.deinit();
    return switch (request.operation) {
        .prepare => handlePrepare(alloc, request),
        .build => handleBuild(alloc, request),
        .inspect => handleInspect(alloc, request),
        .cancel => handleCancel(alloc, request),
        .record_final => handleRecordFinal(alloc, request),
        .acknowledge_final => handleAcknowledge(alloc, request),
    };
}

fn handlePrepare(alloc: Allocator, request: Request) ![]u8 {
    try requireCount(request.object, 7);
    const payload = try objectString(request.object, "launch_request");
    var decoded = try public_protocol.decodePayload(alloc, payload);
    defer decoded.deinit();
    const launch_request = switch (decoded.message) {
        .launch_request => |value| value,
        else => return error.InvalidLaunchProviderPayload,
    };
    var prepared = try launcher.PreparedLaunch.prepare(alloc, launch_request);
    defer prepared.deinit();
    const receipt = try public_protocol.encodePayload(
        alloc,
        .{ .launch_receipt = prepared.launchReceipt(launch_request.request_id) },
    );
    defer alloc.free(receipt);
    return encodePayloadResult(alloc, request, "launch_receipt", receipt);
}

fn handleBuild(alloc: Allocator, request: Request) ![]u8 {
    try requireCount(request.object, 13);
    var prepared = try openCorrelated(alloc, request.object);
    defer prepared.deinit();
    const mode_text = try objectString(request.object, "mode");
    const mode: launcher.SpawnMode = if (std.mem.eql(u8, mode_text, "initial"))
        .initial
    else if (std.mem.eql(u8, mode_text, "recover_after_definitive_end"))
        .recover_after_definitive_end
    else
        return error.InvalidLaunchProviderMode;
    const launch_controls = try objectString(request.object, "launch_controls");
    var decoded_controls = try decodeLaunchControls(alloc, launch_controls);
    defer decoded_controls.deinit();
    const args_digest = try objectString(request.object, "remaining_launch_controls_digest");
    var invocation = try prepared.buildExternalInvocation(decoded_controls.args, args_digest, mode);
    defer invocation.deinit();

    var out = try responsePrefix(alloc, request);
    errdefer out.deinit();
    try out.writer.writeAll("\"result\":{\"arguments\":[");
    for (invocation.arguments, 0..) |arg, index| {
        if (index != 0) try out.writer.writeByte(',');
        try writeString(&out.writer, arg);
    }
    try out.writer.writeAll("],\"cwd\":");
    try writeString(&out.writer, invocation.cwd);
    try out.writer.writeAll(",\"environment\":{");
    const environment = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = child_runtime.admission_key_env, .value = invocation.admission_key },
        .{ .key = child_runtime.conversation_id_env, .value = invocation.conversation_id },
        .{ .key = child_runtime.launch_digest_env, .value = invocation.launch_digest },
        .{ .key = child_runtime.launch_id_env, .value = invocation.launch_id },
        .{ .key = child_runtime.state_root_env, .value = invocation.state_root },
    };
    for (environment, 0..) |entry, index| {
        if (index != 0) try out.writer.writeByte(',');
        try writeString(&out.writer, entry.key);
        try out.writer.writeByte(':');
        try writeString(&out.writer, entry.value);
    }
    if (invocation.effort) |effort| {
        try out.writer.writeAll(",\"FX_EFFORT\":");
        try writeString(&out.writer, effort);
    }
    if (invocation.model) |model| {
        try out.writer.writeAll(",\"FX_MODEL\":");
        try writeString(&out.writer, model);
    }
    try out.writer.writeAll("},\"mode\":");
    try writeString(&out.writer, mode_text);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn handleInspect(alloc: Allocator, request: Request) ![]u8 {
    try requireCount(request.object, 10);
    var prepared = try openCorrelated(alloc, request.object);
    defer prepared.deinit();
    var loaded = try prepared.retained();
    defer loaded.deinit();
    return encodeInspection(alloc, request, loaded.record);
}

fn handleCancel(alloc: Allocator, request: Request) ![]u8 {
    try requireCount(request.object, 8);
    const payload = try objectString(request.object, "cancel_request");
    var decoded = try public_protocol.decodePayload(alloc, payload);
    defer decoded.deinit();
    const cancel_request = switch (decoded.message) {
        .admission_cancel_request => |value| value,
        else => return error.InvalidLaunchProviderPayload,
    };
    var prepared = try launcher.PreparedLaunch.openExisting(
        alloc,
        try objectString(request.object, "state_root"),
        cancel_request.admission_key,
        cancel_request.launch_digest,
        cancel_request.launch_id,
    );
    defer prepared.deinit();
    var mutation = try prepared.cancel(cancel_request);
    defer mutation.deinit();
    return encodeInspection(alloc, request, mutation.loaded.record);
}

fn handleRecordFinal(alloc: Allocator, request: Request) ![]u8 {
    try requireCount(request.object, 12);
    var prepared = try openCorrelated(alloc, request.object);
    defer prepared.deinit();
    const observed_at = try objectString(request.object, "observed_at");
    const outcome_value = request.object.get("outcome") orelse return error.InvalidLaunchProviderRequest;
    const outcome = try decodeOutcome(outcome_value);
    var loaded = try prepared.recordExternalFinal(outcome, observed_at);
    defer loaded.deinit();
    return encodeInspection(alloc, request, loaded.record);
}

fn handleAcknowledge(alloc: Allocator, request: Request) ![]u8 {
    try requireCount(request.object, 8);
    const payload = try objectString(request.object, "acknowledgement");
    var decoded = try public_protocol.decodePayload(alloc, payload);
    defer decoded.deinit();
    const acknowledgement = switch (decoded.message) {
        .final_receipt_acknowledgement => |value| value,
        else => return error.InvalidLaunchProviderPayload,
    };
    var prepared = try launcher.PreparedLaunch.openExisting(
        alloc,
        try objectString(request.object, "state_root"),
        acknowledgement.admission_key,
        acknowledgement.launch_digest,
        acknowledgement.launch_id,
    );
    defer prepared.deinit();
    var loaded = try prepared.acknowledgeFinal(acknowledgement);
    defer loaded.deinit();
    return encodeInspection(alloc, request, loaded.record);
}

fn openCorrelated(alloc: Allocator, object: std.json.ObjectMap) !launcher.PreparedLaunch {
    return launcher.PreparedLaunch.openExisting(
        alloc,
        try objectString(object, "state_root"),
        try objectString(object, "admission_key"),
        try objectString(object, "launch_digest"),
        try objectString(object, "launch_id"),
    );
}

fn decodeOutcome(value: std.json.Value) !public_protocol.Outcome {
    if (value != .object) return error.InvalidLaunchProviderOutcome;
    const object = value.object;
    const kind = try objectString(object, "kind");
    if (std.mem.eql(u8, kind, "exited")) {
        try requireCount(object, 2);
        const code = try objectU8(object, "code");
        return .{ .exited = code };
    }
    if (std.mem.eql(u8, kind, "signalled")) {
        try requireCount(object, 2);
        const signal = try objectU8(object, "signal");
        if (signal == 0) return error.InvalidLaunchProviderOutcome;
        return .{ .signalled = signal };
    }
    if (std.mem.eql(u8, kind, "exec_failed")) {
        try requireCount(object, 2);
        const message = try objectString(object, "message");
        try public_protocol.validateBoundedText(message, 1024);
        return .{ .exec_failed = message };
    }
    return error.InvalidLaunchProviderOutcome;
}

const DecodedLaunchControls = struct {
    arena: std.heap.ArenaAllocator,
    args: []const []const u8,

    fn deinit(self: *DecodedLaunchControls) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn decodeLaunchControls(alloc: Allocator, payload: []const u8) !DecodedLaunchControls {
    if (payload.len == 0 or payload.len > max_launch_controls_bytes or !std.unicode.utf8ValidateSlice(payload)) {
        return error.InvalidLaunchControls;
    }
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        payload,
        .{
            .allocate = .alloc_always,
            .parse_numbers = false,
            .duplicate_field_behavior = .@"error",
        },
    ) catch return error.InvalidLaunchControls;
    if (value != .object or value.object.count() != 1) return error.InvalidLaunchControls;
    const args_value = value.object.get("remaining_global_args") orelse return error.InvalidLaunchControls;
    if (args_value != .array or args_value.array.items.len > 128) return error.InvalidLaunchControls;
    const args = try arena.allocator().alloc([]const u8, args_value.array.items.len);
    for (args_value.array.items, 0..) |item, index| {
        if (item != .string or item.string.len == 0 or item.string.len > 1024) return error.InvalidLaunchControls;
        args[index] = item.string;
    }
    const canonical = launcher.encodeLaunchControls(alloc, args) catch return error.InvalidLaunchControls;
    defer alloc.free(canonical);
    if (!std.mem.eql(u8, canonical, payload)) return error.InvalidLaunchControls;
    return .{ .arena = arena, .args = args };
}

fn encodeInspection(alloc: Allocator, request: Request, record: anytype) ![]u8 {
    const launch_receipt = try public_protocol.encodePayload(
        alloc,
        .{ .launch_receipt = record.launchReceipt(record.request_id) },
    );
    defer alloc.free(launch_receipt);
    const decision = if (record.decision) |value|
        try public_protocol.encodePayload(alloc, .{ .admission_decision = value })
    else
        null;
    defer if (decision) |value| alloc.free(value);
    const final_receipt = if (record.final_receipt) |value|
        try public_protocol.encodePayload(alloc, .{ .final_receipt = value })
    else
        null;
    defer if (final_receipt) |value| alloc.free(value);

    var out = try responsePrefix(alloc, request);
    errdefer out.deinit();
    try out.writer.writeAll("\"result\":{\"decision\":");
    if (decision) |value| try writeString(&out.writer, value) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"final_acknowledgement_id\":");
    if (record.final_acknowledgement_id) |value| try writeString(&out.writer, value) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"final_receipt\":");
    if (final_receipt) |value| try writeString(&out.writer, value) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"launch_receipt\":");
    try writeString(&out.writer, launch_receipt);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn encodePayloadResult(alloc: Allocator, request: Request, key: []const u8, payload: []const u8) ![]u8 {
    var out = try responsePrefix(alloc, request);
    errdefer out.deinit();
    try out.writer.writeAll("\"result\":{");
    try writeString(&out.writer, key);
    try out.writer.writeByte(':');
    try writeString(&out.writer, payload);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn responsePrefix(alloc: Allocator, request: Request) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"instance_id\":");
    try writeString(&out.writer, try objectString(request.object, "instance_id"));
    try out.writer.writeAll(",\"ok\":true,\"request_id\":");
    try writeString(&out.writer, request.request_id);
    try out.writer.writeAll(",\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,");
    return out;
}

fn encodeError(alloc: Allocator, instance_id: []const u8, request_id: ?[]u8, code: []const u8) ![]u8 {
    defer if (request_id) |value| alloc.free(value);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"error\":{\"code\":");
    try writeString(&out.writer, code);
    try out.writer.writeAll("},\"instance_id\":");
    try writeString(&out.writer, instance_id);
    try out.writer.writeAll(",\"ok\":false,\"request_id\":");
    if (request_id) |value| try writeString(&out.writer, value) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1}");
    return out.toOwnedSlice();
}

fn decodeRequest(alloc: Allocator, frame: []const u8, instance_id: []const u8, token: []const u8) !Request {
    if (frame.len == 0 or frame.len > max_frame_bytes or !std.unicode.utf8ValidateSlice(frame)) {
        return error.InvalidLaunchProviderFrame;
    }
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        frame,
        .{
            .allocate = .alloc_always,
            .parse_numbers = false,
            .duplicate_field_behavior = .@"error",
        },
    ) catch |err| switch (err) {
        error.DuplicateField => return error.DuplicateLaunchProviderField,
        else => return error.InvalidLaunchProviderJson,
    };
    if (value != .object) return error.InvalidLaunchProviderRequest;
    const object = value.object;
    if (!std.mem.eql(u8, try objectString(object, "schema_id"), schema_id)) return error.UnsupportedLaunchProviderSchema;
    const version = object.get("schema_version") orelse return error.InvalidLaunchProviderRequest;
    if (version != .number_string or !std.mem.eql(u8, version.number_string, "1")) {
        return error.UnsupportedLaunchProviderVersion;
    }
    if (!std.mem.eql(u8, try objectString(object, "instance_id"), instance_id)) {
        return error.LaunchProviderInstanceMismatch;
    }
    if (!tokensEqual(try objectString(object, "token"), token)) return error.LaunchProviderUnauthorized;
    const request_id = try objectString(object, "request_id");
    try public_protocol.validateSafeToken(request_id);
    const operation_text = try objectString(object, "operation");
    const operation = std.meta.stringToEnum(Operation, operation_text) orelse
        return error.UnknownLaunchProviderOperation;
    return .{ .arena = arena, .request_id = request_id, .operation = operation, .object = object };
}

fn tokensEqual(a: []const u8, b: []const u8) bool {
    var a_digest: [32]u8 = undefined;
    var b_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(a, &a_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(b, &b_digest, .{});
    return std.crypto.timing_safe.eql([32]u8, a_digest, b_digest) and a.len == b.len;
}

fn requireCount(object: std.json.ObjectMap, expected: usize) !void {
    if (object.count() != expected) return error.InvalidLaunchProviderRequest;
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidLaunchProviderRequest;
    if (value != .string) return error.InvalidLaunchProviderRequest;
    return value.string;
}

fn objectU8(object: std.json.ObjectMap, key: []const u8) !u8 {
    const value = object.get(key) orelse return error.InvalidLaunchProviderRequest;
    if (value != .number_string) return error.InvalidLaunchProviderRequest;
    return std.fmt.parseInt(u8, value.number_string, 10) catch error.InvalidLaunchProviderRequest;
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn requestIdBestEffort(alloc: Allocator, frame: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, frame, .{
        .duplicate_field_behavior = .@"error",
    }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("request_id") orelse return null;
    if (value != .string or value.string.len == 0 or value.string.len > 256) return null;
    return alloc.dupe(u8, value.string) catch null;
}

fn nativeStatFd(fd: std.posix.fd_t) !std.c.Stat {
    while (true) {
        var stat = std.mem.zeroes(std.c.Stat);
        switch (std.c.errno(std.c.fstat(fd, &stat))) {
            .SUCCESS => return stat,
            .INTR => continue,
            else => return error.LaunchProviderFilesystemStatFailed,
        }
    }
}

fn nativeStatAt(dir_fd: std.posix.fd_t, name: [:0]const u8) !std.c.Stat {
    while (true) {
        var stat = std.mem.zeroes(std.c.Stat);
        switch (std.c.errno(std.c.fstatat(
            dir_fd,
            name.ptr,
            &stat,
            std.c.AT.SYMLINK_NOFOLLOW,
        ))) {
            .SUCCESS => return stat,
            .INTR => continue,
            else => return error.LaunchProviderFilesystemStatFailed,
        }
    }
}

fn sameFileIdentity(a: std.c.Stat, b: std.c.Stat) bool {
    return a.dev == b.dev and a.ino == b.ino and a.uid == b.uid;
}

fn validateEndpointDirectory(stat: std.c.Stat) !void {
    if (!std.c.S.ISDIR(stat.mode) or
        stat.uid != std.c.geteuid() or
        stat.mode & 0o777 != 0o700)
    {
        return error.LaunchProviderDirectoryUnsafe;
    }
}

fn validateSocketIdentity(stat: std.c.Stat, require_private_mode: bool) !void {
    if (!std.c.S.ISSOCK(stat.mode) or stat.uid != std.c.geteuid()) {
        return error.LaunchProviderSocketUnsafe;
    }
    if (require_private_mode and stat.mode & 0o777 != 0o600) {
        return error.LaunchProviderSocketUnsafe;
    }
}

fn readFrame(alloc: Allocator, socket: std.Io.net.Socket) ![]u8 {
    const deadline = io_mod.milliTimestamp() + peer_timeout_ms;
    var header: [4]u8 = undefined;
    try receiveExact(socket, &header, deadline);
    const len: usize = std.mem.readInt(u32, &header, .big);
    if (len == 0 or len > max_frame_bytes) return error.InvalidLaunchProviderFrame;
    const frame = try alloc.alloc(u8, len);
    errdefer alloc.free(frame);
    try receiveExact(socket, frame, deadline);
    return frame;
}

fn receiveExact(socket: std.Io.net.Socket, destination: []u8, deadline: i64) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const remaining = deadline - io_mod.milliTimestamp();
        if (remaining <= 0) return error.LaunchProviderReadTimeout;
        const incoming = socket.receiveTimeout(io_mod.getIo(), destination[offset..], .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(@intCast(@min(remaining, 100))),
        } }) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        if (incoming.data.len == 0) return error.EndOfStream;
        offset += incoming.data.len;
    }
}

fn writeFrame(fd: std.posix.fd_t, payload: []const u8) !void {
    if (payload.len > max_frame_bytes) return error.LaunchProviderResponseTooLarge;
    var frame = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer frame.deinit();
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
    try frame.writer.writeAll(&header);
    try frame.writer.writeAll(payload);
    try setNonblocking(fd);
    const deadline = io_mod.milliTimestamp() + peer_timeout_ms;
    var offset: usize = 0;
    while (offset < frame.written().len) {
        if (io_mod.milliTimestamp() >= deadline) return error.LaunchProviderWriteTimeout;
        const rc = std.c.send(fd, frame.written()[offset..].ptr, frame.written().len - offset, std.posix.MSG.NOSIGNAL);
        switch (std.c.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.LaunchProviderWriteFailed;
                offset += @intCast(rc);
            },
            .INTR => continue,
            .AGAIN => {
                var poll_fds = [_]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = try std.posix.poll(&poll_fds, 25);
            },
            else => return error.LaunchProviderWriteFailed,
        }
    }
}

fn listenerReady(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = try std.posix.poll(&poll_fds, timeout_ms);
    return (poll_fds[0].revents & std.posix.POLL.IN) != 0;
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const current = while (true) {
        const rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return error.LaunchProviderSocketOptionFailed,
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
        else => return error.LaunchProviderSocketOptionFailed,
    };
}

var stable_provider_test_environ: ?*std.process.Environ.Map = null;

fn installProviderTestEnviron() !void {
    if (stable_provider_test_environ == null) {
        const alloc = std.heap.page_allocator;
        const map = try alloc.create(std.process.Environ.Map);
        map.* = std.process.Environ.Map.init(alloc);
        stable_provider_test_environ = map;
    }
    io_mod.setEnvironMap(stable_provider_test_environ.?);
}

test "private launch provider prepares builds inspects and records external final receipts" {
    const alloc = std.testing.allocator;
    try installProviderTestEnviron();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const args = [_][]const u8{
        "--no-additional-dirs",
        "--no-native-tools",
        "--no-default-skills",
        "--no-project-instructions",
        "--system-prompt-file=/tmp/system",
        "--append-system-prompt-file",
        "/tmp/append",
        "--skills-dir=/tmp/skills",
        "--context-limit",
        "max:1",
        "--add-dir=/tmp/add",
        "--tool",
        "read",
        "--permissions-file=/tmp/permissions",
    };
    const args_digest = try launcher.computeLaunchControlsDigest(alloc, &args);
    const launch_controls = try launcher.encodeLaunchControls(alloc, &args);
    defer alloc.free(launch_controls);
    var launch_request: public_protocol.LaunchRequest = .{
        .admission_key = "provider-key",
        .conversation_name = "Provider fixture",
        .directory = root,
        .effort = "medium",
        .initial_work_digest = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .launch_digest = &([_]u8{'0'} ** 64),
        .launch_id = "provider-launch",
        .model = "fixture/model",
        .remaining_launch_controls_digest = &args_digest,
        .request_id = "public-prepare",
        .resume_target = .fresh,
        .state_root = root,
    };
    var launch_digest = try public_protocol.computeLaunchDigest(alloc, launch_request);
    launch_request.launch_digest = &launch_digest;
    const public_frame = try public_protocol.encodePayload(alloc, .{ .launch_request = launch_request });
    defer alloc.free(public_frame);

    var prepare = std.Io.Writer.Allocating.init(alloc);
    defer prepare.deinit();
    try prepare.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"prepare\",\"operation\":\"prepare\",\"launch_request\":");
    try writeString(&prepare.writer, public_frame);
    try prepare.writer.writeByte('}');
    const prepared_response = try handleFrame(alloc, prepare.written(), "instance", "01234567890123456789012345678901");
    defer alloc.free(prepared_response);
    try std.testing.expect(std.mem.find(u8, prepared_response, "\\\"message_type\\\":\\\"launch_receipt\\\"") != null);

    var build = std.Io.Writer.Allocating.init(alloc);
    defer build.deinit();
    try build.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"build\",\"operation\":\"build\",\"state_root\":");
    try writeString(&build.writer, root);
    try build.writer.writeAll(",\"admission_key\":\"provider-key\",\"launch_digest\":");
    try writeString(&build.writer, &launch_digest);
    try build.writer.writeAll(",\"launch_id\":\"provider-launch\",\"mode\":\"initial\",\"launch_controls\":");
    try writeString(&build.writer, launch_controls);
    try build.writer.writeAll(",\"remaining_launch_controls_digest\":");
    try writeString(&build.writer, &args_digest);
    try build.writer.writeByte('}');
    const build_response = try handleFrame(alloc, build.written(), "instance", "01234567890123456789012345678901");
    defer alloc.free(build_response);
    try std.testing.expect(std.mem.find(u8, build_response, child_runtime.conversation_id_env) != null);
    try std.testing.expect(std.mem.find(u8, build_response, "\"arguments\":[\"--state-dir\"") != null);
    try std.testing.expect(std.mem.find(u8, build_response, "\"FX_MODEL\":\"fixture/model\"") != null);
    try std.testing.expect(std.mem.find(u8, build_response, "\"FX_EFFORT\":\"medium\"") != null);

    const inherited_environment = stable_provider_test_environ.?;
    try inherited_environment.put("FX_MODEL", "inherited/model");
    defer _ = inherited_environment.orderedRemove("FX_MODEL");
    try inherited_environment.put("FX_EFFORT", "high");
    defer _ = inherited_environment.orderedRemove("FX_EFFORT");
    const no_override_args = [_][]const u8{};
    const no_override_args_digest = try launcher.computeLaunchControlsDigest(alloc, &no_override_args);
    const no_override_controls = try launcher.encodeLaunchControls(alloc, &no_override_args);
    defer alloc.free(no_override_controls);
    var no_override_request: public_protocol.LaunchRequest = .{
        .admission_key = "provider-no-override-key",
        .conversation_name = "Provider without overrides",
        .directory = root,
        .effort = null,
        .initial_work_digest = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        .launch_digest = &([_]u8{'0'} ** 64),
        .launch_id = "provider-no-override-launch",
        .model = null,
        .remaining_launch_controls_digest = &no_override_args_digest,
        .request_id = "public-no-override-prepare",
        .resume_target = .fresh,
        .state_root = root,
    };
    var no_override_digest = try public_protocol.computeLaunchDigest(alloc, no_override_request);
    no_override_request.launch_digest = &no_override_digest;
    var no_override_prepared = try launcher.PreparedLaunch.prepare(alloc, no_override_request);
    defer no_override_prepared.deinit();
    var no_override_invocation = try no_override_prepared.buildExternalInvocation(
        &no_override_args,
        &no_override_args_digest,
        .initial,
    );
    defer no_override_invocation.deinit();
    try std.testing.expect(no_override_invocation.model == null);
    try std.testing.expect(no_override_invocation.effort == null);

    var no_override_build = std.Io.Writer.Allocating.init(alloc);
    defer no_override_build.deinit();
    try no_override_build.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"no-override-build\",\"operation\":\"build\",\"state_root\":");
    try writeString(&no_override_build.writer, root);
    try no_override_build.writer.writeAll(",\"admission_key\":\"provider-no-override-key\",\"launch_digest\":");
    try writeString(&no_override_build.writer, &no_override_digest);
    try no_override_build.writer.writeAll(",\"launch_id\":\"provider-no-override-launch\",\"mode\":\"initial\",\"launch_controls\":");
    try writeString(&no_override_build.writer, no_override_controls);
    try no_override_build.writer.writeAll(",\"remaining_launch_controls_digest\":");
    try writeString(&no_override_build.writer, &no_override_args_digest);
    try no_override_build.writer.writeByte('}');
    const no_override_response = try handleFrame(
        alloc,
        no_override_build.written(),
        "instance",
        "01234567890123456789012345678901",
    );
    defer alloc.free(no_override_response);
    try std.testing.expect(std.mem.find(u8, no_override_response, "FX_MODEL") == null);
    try std.testing.expect(std.mem.find(u8, no_override_response, "FX_EFFORT") == null);

    const cancel_payload = try public_protocol.encodePayload(alloc, .{ .admission_cancel_request = .{
        .admission_key = "provider-key",
        .launch_digest = &launch_digest,
        .launch_id = "provider-launch",
        .request_id = "cancel-request",
    } });
    defer alloc.free(cancel_payload);
    var cancel = std.Io.Writer.Allocating.init(alloc);
    defer cancel.deinit();
    try cancel.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"cancel\",\"operation\":\"cancel\",\"state_root\":");
    try writeString(&cancel.writer, root);
    try cancel.writer.writeAll(",\"cancel_request\":");
    try writeString(&cancel.writer, cancel_payload);
    try cancel.writer.writeByte('}');
    const cancel_response = try handleFrame(alloc, cancel.written(), "instance", "01234567890123456789012345678901");
    defer alloc.free(cancel_response);
    try std.testing.expect(std.mem.find(u8, cancel_response, "cancelled_before_start") != null);

    var inspect = std.Io.Writer.Allocating.init(alloc);
    defer inspect.deinit();
    try inspect.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"inspect\",\"operation\":\"inspect\",\"state_root\":");
    try writeString(&inspect.writer, root);
    try inspect.writer.writeAll(",\"admission_key\":\"provider-key\",\"launch_digest\":");
    try writeString(&inspect.writer, &launch_digest);
    try inspect.writer.writeAll(",\"launch_id\":\"provider-launch\"}");
    const inspect_response = try handleFrame(alloc, inspect.written(), "instance", "01234567890123456789012345678901");
    defer alloc.free(inspect_response);
    try std.testing.expect(std.mem.find(u8, inspect_response, "cancelled_before_start") != null);

    var record_final = std.Io.Writer.Allocating.init(alloc);
    defer record_final.deinit();
    try record_final.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"record-final\",\"operation\":\"record_final\",\"state_root\":");
    try writeString(&record_final.writer, root);
    try record_final.writer.writeAll(",\"admission_key\":\"provider-key\",\"launch_digest\":");
    try writeString(&record_final.writer, &launch_digest);
    try record_final.writer.writeAll(",\"launch_id\":\"provider-launch\",\"observed_at\":\"1970-01-01T00:00:00.000Z\",\"outcome\":{\"kind\":\"exited\",\"code\":7}}");
    const final_response = try handleFrame(alloc, record_final.written(), "instance", "01234567890123456789012345678901");
    defer alloc.free(final_response);
    try std.testing.expect(std.mem.find(u8, final_response, "exec_failed") == null);

    var prepared = try launcher.PreparedLaunch.openExisting(alloc, root, "provider-key", &launch_digest, "provider-launch");
    defer prepared.deinit();
    const forbidden_args = [_][]const u8{ "--state-dir", root };
    try std.testing.expectError(
        error.ProviderOwnedLaunchControl,
        prepared.buildExternalInvocation(&forbidden_args, &args_digest, .initial),
    );
    const control_args = [_][]const u8{ "--model", "bad\x00value" };
    try std.testing.expectError(
        error.InvalidLaunchControlArgument,
        prepared.buildExternalInvocation(&control_args, &args_digest, .initial),
    );
    var final = try prepared.retained();
    defer final.deinit();
    try std.testing.expectEqual(@as(u8, 7), final.record.final_receipt.?.outcome.exited);

    const retained_final = final.record.final_receipt.?;
    const acknowledgement_payload = try public_protocol.encodePayload(alloc, .{ .final_receipt_acknowledgement = .{
        .acknowledgement_id = "provider-ack",
        .admission_key = retained_final.admission_key,
        .conversation_id = retained_final.conversation_id,
        .launch_digest = retained_final.launch_digest,
        .launch_id = retained_final.launch_id,
        .receipt_digest = retained_final.receipt_digest,
        .receipt_id = retained_final.receipt_id,
    } });
    defer alloc.free(acknowledgement_payload);
    var acknowledge = std.Io.Writer.Allocating.init(alloc);
    defer acknowledge.deinit();
    try acknowledge.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"ack\",\"operation\":\"acknowledge_final\",\"state_root\":");
    try writeString(&acknowledge.writer, root);
    try acknowledge.writer.writeAll(",\"acknowledgement\":");
    try writeString(&acknowledge.writer, acknowledgement_payload);
    try acknowledge.writer.writeByte('}');
    const acknowledgement_response = try handleFrame(alloc, acknowledge.written(), "instance", "01234567890123456789012345678901");
    defer alloc.free(acknowledgement_response);
    try std.testing.expect(std.mem.find(u8, acknowledgement_response, "provider-ack") != null);
}

test "private launch provider rejects wrong auth unknown fields and conflicting correlation" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidLaunchControlArgument,
        launcher.encodeLaunchControls(alloc, &.{"--unknown"}),
    );
    try std.testing.expectError(
        error.InvalidLaunchControlArgument,
        launcher.encodeLaunchControls(alloc, &.{"--skills-dir"}),
    );
    try std.testing.expectError(
        error.InvalidLaunchControlArgument,
        launcher.encodeLaunchControls(alloc, &.{ "--skills-dir", "--no-native-tools" }),
    );
    const oversized_arg = try alloc.alloc(u8, 1025);
    defer alloc.free(oversized_arg);
    @memset(oversized_arg, 'x');
    try std.testing.expectError(
        error.InvalidLaunchControlArgument,
        launcher.encodeLaunchControls(alloc, &.{ "--skills-dir", oversized_arg }),
    );
    try std.testing.expectError(
        error.InvalidLaunchControls,
        decodeLaunchControls(alloc, "{ \"remaining_global_args\":[]}"),
    );
    const oversized = try alloc.alloc(u8, max_launch_controls_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.InvalidLaunchControls,
        decodeLaunchControls(alloc, oversized),
    );
    const wrong_auth = "{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"wrong\",\"request_id\":\"inspect\",\"operation\":\"inspect\",\"state_root\":\"/tmp\",\"admission_key\":\"key\",\"launch_digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"launch_id\":\"launch\"}";
    try std.testing.expectError(
        error.LaunchProviderUnauthorized,
        handleFrame(alloc, wrong_auth, "instance", "01234567890123456789012345678901"),
    );
    const unknown = "{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"inspect\",\"operation\":\"inspect\",\"state_root\":\"/tmp\",\"admission_key\":\"key\",\"launch_digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"launch_id\":\"launch\",\"extra\":true}";
    try std.testing.expectError(
        error.InvalidLaunchProviderRequest,
        handleFrame(alloc, unknown, "instance", "01234567890123456789012345678901"),
    );
    const duplicate_top_level = "{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"first\",\"request_id\":\"second\",\"operation\":\"inspect\",\"state_root\":\"/tmp\",\"admission_key\":\"key\",\"launch_digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"launch_id\":\"launch\"}";
    try std.testing.expectError(
        error.DuplicateLaunchProviderField,
        handleFrame(alloc, duplicate_top_level, "instance", "01234567890123456789012345678901"),
    );
    const duplicate_nested = "{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"nested\",\"operation\":\"record_final\",\"state_root\":\"/tmp\",\"admission_key\":\"key\",\"launch_digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"launch_id\":\"launch\",\"observed_at\":\"1970-01-01T00:00:00.000Z\",\"outcome\":{\"kind\":\"exited\",\"kind\":\"signalled\",\"code\":0}}";
    try std.testing.expectError(
        error.DuplicateLaunchProviderField,
        handleFrame(alloc, duplicate_nested, "instance", "01234567890123456789012345678901"),
    );
}

test "private launch provider endpoint directory is exact user-owned mode 0700" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_parent = try std.Io.Dir.openDirAbsolute(std.testing.io, "/tmp", .{});
    defer tmp_parent.close(std.testing.io);
    const tmp_name = try std.fmt.allocPrint(alloc, "fx-lp-{s}", .{tmp.sub_path[0..]});
    defer alloc.free(tmp_name);
    try tmp_parent.createDir(std.testing.io, tmp_name, .fromMode(0o700));
    defer tmp_parent.deleteTree(std.testing.io, tmp_name) catch {};
    const root = try io_mod.dirRealpathAlloc(alloc, tmp_parent, tmp_name);
    defer alloc.free(root);
    const endpoint = try std.fs.path.join(alloc, &.{ root, "endpoint" });
    defer alloc.free(endpoint);
    var verified = try EndpointDirectory.create(alloc, endpoint);
    defer verified.deinit();
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, endpoint, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    try std.testing.expectEqual(@as(u16, 0o700), stat.permissions.toMode() & 0o777);
    try std.testing.expectError(
        error.LaunchProviderDirectoryNotFresh,
        EndpointDirectory.create(alloc, endpoint),
    );

    const anchored_socket = try std.fs.path.join(alloc, &.{ endpoint, socket_name });
    defer alloc.free(anchored_socket);
    {
        const anchored_address = try std.Io.net.UnixAddress.init(anchored_socket);
        var anchored_server = try anchored_address.listen(std.testing.io, .{});
        defer anchored_server.deinit(std.testing.io);
        try verified.secureBoundSocket();
        try verified.verifyBoundSocket();
        const socket_stat = try verified.dir.statFile(std.testing.io, socket_name, .{
            .follow_symlinks = false,
        });
        try std.testing.expectEqual(std.Io.File.Kind.unix_domain_socket, socket_stat.kind);
        try std.testing.expectEqual(@as(u16, 0o600), socket_stat.permissions.toMode() & 0o777);
    }
    try verified.dir.deleteFile(std.testing.io, socket_name);

    const retained = try std.fs.path.join(alloc, &.{ root, "endpoint-retained" });
    defer alloc.free(retained);
    try std.Io.Dir.renameAbsolute(endpoint, retained, std.testing.io);
    try std.Io.Dir.createDirAbsolute(std.testing.io, endpoint, .fromMode(0o700));
    const replacement_socket = try std.fs.path.join(alloc, &.{ endpoint, socket_name });
    defer alloc.free(replacement_socket);
    const address = try std.Io.net.UnixAddress.init(replacement_socket);
    var replacement_server = try address.listen(std.testing.io, .{});
    defer replacement_server.deinit(std.testing.io);
    try std.testing.expectError(
        error.LaunchProviderDirectorySubstituted,
        verified.secureBoundSocket(),
    );
    try std.testing.expect(!verified.childPathStillAnchored());
}
