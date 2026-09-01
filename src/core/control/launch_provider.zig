const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const public_protocol = @import("launch_admission_final.zig");
const launcher = @import("launch_admission_final_launcher.zig");
const child_runtime = @import("launch_admission_final_runtime.zig");

const Allocator = std.mem.Allocator;

pub const schema_id = "fx.private-launch-provider";
pub const schema_version: u16 = 1;
pub const schema_version_resume_status: u16 = 2;
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
    resume_status,
    cancel,
    record_final,
    acknowledge_final,
};

const Request = struct {
    arena: std.heap.ArenaAllocator,
    request_id: []const u8,
    schema_version: u16,
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
        try encodeError(
            alloc,
            instance_id,
            requestIdBestEffort(alloc, frame),
            schemaVersionBestEffort(alloc, frame),
            @errorName(err),
        );
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
        .resume_status => handleResumeStatus(alloc, request),
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

const resume_status_authority = "fx.private-launch-provider/resume-status-v2";

fn handleResumeStatus(alloc: Allocator, request: Request) ![]u8 {
    if (request.schema_version != schema_version_resume_status) {
        return error.UnknownLaunchProviderOperation;
    }
    try requireCount(request.object, 10);
    var prepared = try openCorrelated(alloc, request.object);
    defer prepared.deinit();
    const status = try prepared.exactResumeStatus();

    const identity_digest = try resumeStatusIdentityDigest(alloc, status);
    var decision_id_buffer: ["resume-status-".len + 64]u8 = undefined;
    const decision_id = try std.fmt.bufPrint(
        &decision_id_buffer,
        "resume-status-{s}",
        .{&identity_digest},
    );
    const decision_digest = try resumeStatusDecisionDigest(
        alloc,
        status,
        decision_id,
    );

    var out = try responsePrefix(alloc, request);
    errdefer out.deinit();
    try out.writer.writeAll("\"result\":{\"resume_status\":{\"admission_key\":");
    try writeString(&out.writer, status.admission_key);
    try out.writer.writeAll(",\"authority\":\"");
    try out.writer.writeAll(resume_status_authority);
    try out.writer.writeAll("\",\"conversation_id\":");
    try writeString(&out.writer, status.conversation_id);
    try out.writer.writeAll(",\"decision_digest\":");
    try writeString(&out.writer, &decision_digest);
    try out.writer.writeAll(",\"decision_id\":");
    try writeString(&out.writer, decision_id);
    try out.writer.writeAll(",\"launch_digest\":");
    try writeString(&out.writer, status.launch_digest);
    try out.writer.writeAll(",\"launch_id\":");
    try writeString(&out.writer, status.launch_id);
    try out.writer.writeAll(",\"semantic_decision\":");
    try writeString(&out.writer, resumeStatusSemanticDecision(status.available));
    try out.writer.writeAll(",\"state_root\":");
    try writeString(&out.writer, status.state_root);
    try out.writer.writeAll(",\"status\":");
    try writeString(&out.writer, resumeStatusName(status.available));
    try out.writer.writeAll("}}}");
    return out.toOwnedSlice();
}

fn resumeStatusIdentityDigest(
    alloc: Allocator,
    status: launcher.ExactResumeStatus,
) ![64]u8 {
    var canonical: std.Io.Writer.Allocating = .init(alloc);
    defer canonical.deinit();
    try writeResumeStatusDecisionFields(&canonical.writer, status, null);
    return sha256Hex(canonical.written());
}

fn resumeStatusDecisionDigest(
    alloc: Allocator,
    status: launcher.ExactResumeStatus,
    decision_id: []const u8,
) ![64]u8 {
    var canonical: std.Io.Writer.Allocating = .init(alloc);
    defer canonical.deinit();
    try writeResumeStatusDecisionFields(&canonical.writer, status, decision_id);
    return sha256Hex(canonical.written());
}

fn writeResumeStatusDecisionFields(
    writer: *std.Io.Writer,
    status: launcher.ExactResumeStatus,
    decision_id: ?[]const u8,
) !void {
    try writer.writeAll("{\"admission_key\":");
    try writeString(writer, status.admission_key);
    try writer.writeAll(",\"authority\":\"");
    try writer.writeAll(resume_status_authority);
    try writer.writeAll("\",\"conversation_id\":");
    try writeString(writer, status.conversation_id);
    if (decision_id) |value| {
        try writer.writeAll(",\"decision_id\":");
        try writeString(writer, value);
    }
    try writer.writeAll(",\"launch_digest\":");
    try writeString(writer, status.launch_digest);
    try writer.writeAll(",\"launch_id\":");
    try writeString(writer, status.launch_id);
    try writer.writeAll(",\"semantic_decision\":");
    try writeString(writer, resumeStatusSemanticDecision(status.available));
    try writer.writeAll(",\"state_root\":");
    try writeString(writer, status.state_root);
    try writer.writeAll(",\"status\":");
    try writeString(writer, resumeStatusName(status.available));
    try writer.writeByte('}');
}

fn resumeStatusName(available: bool) []const u8 {
    return if (available) "available" else "unavailable";
}

fn resumeStatusSemanticDecision(available: bool) []const u8 {
    return if (available) "exact_resume_available" else "exact_resume_unavailable";
}

fn sha256Hex(payload: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
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
    try out.writer.writeAll(",\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":");
    try out.writer.print("{d},", .{request.schema_version});
    return out;
}

fn encodeError(
    alloc: Allocator,
    instance_id: []const u8,
    request_id: ?[]u8,
    request_schema_version: u16,
    code: []const u8,
) ![]u8 {
    defer if (request_id) |value| alloc.free(value);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"error\":{\"code\":");
    try writeString(&out.writer, code);
    try out.writer.writeAll("},\"instance_id\":");
    try writeString(&out.writer, instance_id);
    try out.writer.writeAll(",\"ok\":false,\"request_id\":");
    if (request_id) |value| try writeString(&out.writer, value) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":");
    try out.writer.print("{d}}}", .{request_schema_version});
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
    const version_value = object.get("schema_version") orelse return error.InvalidLaunchProviderRequest;
    if (version_value != .number_string) return error.UnsupportedLaunchProviderVersion;
    const version = std.fmt.parseInt(u16, version_value.number_string, 10) catch
        return error.UnsupportedLaunchProviderVersion;
    if (version != schema_version and version != schema_version_resume_status) {
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
    if (operation == .resume_status and version != schema_version_resume_status) {
        return error.UnknownLaunchProviderOperation;
    }
    return .{
        .arena = arena,
        .request_id = request_id,
        .schema_version = version,
        .operation = operation,
        .object = object,
    };
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

fn schemaVersionBestEffort(alloc: Allocator, frame: []const u8) u16 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, frame, .{
        .duplicate_field_behavior = .@"error",
    }) catch return schema_version;
    defer parsed.deinit();
    if (parsed.value != .object) return schema_version;
    const value = parsed.value.object.get("schema_version") orelse return schema_version;
    if (value != .integer) return schema_version;
    const version = std.math.cast(u16, value.integer) orelse return schema_version;
    return if (version == schema_version_resume_status) version else schema_version;
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

fn createProviderTestConversation(
    alloc: Allocator,
    state_root: []const u8,
    conversation_id: []const u8,
) !void {
    var store = try session_store.Store.initFromHome(alloc, state_root, state_root);
    defer store.deinit(alloc);
    var state: session_codec.DurableSessionState = .{
        .id = try alloc.dupe(u8, conversation_id),
        .origin_workspace_root = try alloc.dupe(u8, state_root),
        .workspace_root = try alloc.dupe(u8, state_root),
        .created_at_ms = 10,
        .updated_at_ms = 10,
        .conversation_language = .literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "fixture/model"),
            .effort = .literal("medium"),
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    writable.deinit(alloc);
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

test "private launch provider v2 proves exact resume availability through durable Session authority" {
    const alloc = std.testing.allocator;
    try installProviderTestEnviron();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const conversation_id = "1788000000000-1788000000000000000-abcd1234";
    const empty_args = [_][]const u8{};
    const args_digest = try launcher.computeLaunchControlsDigest(alloc, &empty_args);
    var launch_request: public_protocol.LaunchRequest = .{
        .admission_key = "resume-status-key",
        .conversation_name = "Resume status fixture",
        .directory = root,
        .effort = null,
        .initial_work_digest = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .launch_digest = &([_]u8{'0'} ** 64),
        .launch_id = "resume-status-launch",
        .model = null,
        .remaining_launch_controls_digest = &args_digest,
        .request_id = "resume-status-prepare",
        .resume_target = .{ .exact = conversation_id },
        .state_root = root,
    };
    var launch_digest = try public_protocol.computeLaunchDigest(alloc, launch_request);
    launch_request.launch_digest = &launch_digest;
    var prepared = try launcher.PreparedLaunch.prepare(alloc, launch_request);
    defer prepared.deinit();

    var version_one = std.Io.Writer.Allocating.init(alloc);
    defer version_one.deinit();
    try version_one.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"resume-v1\",\"operation\":\"resume_status\",\"state_root\":");
    try writeString(&version_one.writer, root);
    try version_one.writer.writeAll(",\"admission_key\":\"resume-status-key\",\"launch_digest\":");
    try writeString(&version_one.writer, &launch_digest);
    try version_one.writer.writeAll(",\"launch_id\":\"resume-status-launch\"}");
    try std.testing.expectError(
        error.UnknownLaunchProviderOperation,
        handleFrame(
            alloc,
            version_one.written(),
            "instance",
            "01234567890123456789012345678901",
        ),
    );

    var version_one_inspect = std.Io.Writer.Allocating.init(alloc);
    defer version_one_inspect.deinit();
    try version_one_inspect.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"v1-prefix\",\"operation\":\"inspect\",\"state_root\":");
    try writeString(&version_one_inspect.writer, root);
    try version_one_inspect.writer.writeAll(",\"admission_key\":\"resume-status-key\",\"launch_digest\":");
    try writeString(&version_one_inspect.writer, &launch_digest);
    try version_one_inspect.writer.writeAll(",\"launch_id\":\"resume-status-launch\"}");
    var decoded_version_one = try decodeRequest(
        alloc,
        version_one_inspect.written(),
        "instance",
        "01234567890123456789012345678901",
    );
    defer decoded_version_one.deinit();
    var version_one_prefix = try responsePrefix(alloc, decoded_version_one);
    defer version_one_prefix.deinit();
    try std.testing.expectEqualStrings(
        "{\"instance_id\":\"instance\",\"ok\":true,\"request_id\":\"v1-prefix\",\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1,",
        version_one_prefix.written(),
    );
    const version_one_error = try encodeError(
        alloc,
        "instance",
        try alloc.dupe(u8, "v1-error"),
        schema_version,
        "ExampleError",
    );
    defer alloc.free(version_one_error);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"ExampleError\"},\"instance_id\":\"instance\",\"ok\":false,\"request_id\":\"v1-error\",\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":1}",
        version_one_error,
    );
    const version_two_error = try encodeError(
        alloc,
        "instance",
        try alloc.dupe(u8, "v2-error"),
        schema_version_resume_status,
        "ExampleError",
    );
    defer alloc.free(version_two_error);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"ExampleError\"},\"instance_id\":\"instance\",\"ok\":false,\"request_id\":\"v2-error\",\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":2}",
        version_two_error,
    );

    var unavailable_request = std.Io.Writer.Allocating.init(alloc);
    defer unavailable_request.deinit();
    try unavailable_request.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":2,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"resume-unavailable\",\"operation\":\"resume_status\",\"state_root\":");
    try writeString(&unavailable_request.writer, root);
    try unavailable_request.writer.writeAll(",\"admission_key\":\"resume-status-key\",\"launch_digest\":");
    try writeString(&unavailable_request.writer, &launch_digest);
    try unavailable_request.writer.writeAll(",\"launch_id\":\"resume-status-launch\"}");
    const unavailable_response = try handleFrame(
        alloc,
        unavailable_request.written(),
        "instance",
        "01234567890123456789012345678901",
    );
    defer alloc.free(unavailable_response);
    var unavailable_json = try std.json.parseFromSlice(std.json.Value, alloc, unavailable_response, .{});
    defer unavailable_json.deinit();
    const unavailable_result = unavailable_json.value.object.get("result").?.object;
    const unavailable_proof = unavailable_result.get("resume_status").?.object;
    try std.testing.expectEqual(@as(usize, 10), unavailable_proof.count());
    try std.testing.expectEqualStrings("unavailable", try objectString(unavailable_proof, "status"));
    try std.testing.expectEqualStrings(
        "exact_resume_unavailable",
        try objectString(unavailable_proof, "semantic_decision"),
    );
    const unavailable_status = try prepared.exactResumeStatus();
    try std.testing.expect(!unavailable_status.available);
    const unavailable_identity = try resumeStatusIdentityDigest(alloc, unavailable_status);
    var unavailable_id_buffer: ["resume-status-".len + 64]u8 = undefined;
    const unavailable_id = try std.fmt.bufPrint(
        &unavailable_id_buffer,
        "resume-status-{s}",
        .{&unavailable_identity},
    );
    try std.testing.expectEqualStrings(
        unavailable_id,
        try objectString(unavailable_proof, "decision_id"),
    );
    const unavailable_digest = try resumeStatusDecisionDigest(
        alloc,
        unavailable_status,
        unavailable_id,
    );
    try std.testing.expectEqualStrings(
        &unavailable_digest,
        try objectString(unavailable_proof, "decision_digest"),
    );

    const vector_status: launcher.ExactResumeStatus = .{
        .admission_key = "vector-key",
        .available = true,
        .conversation_id = conversation_id,
        .launch_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .launch_id = "vector-launch",
        .state_root = "/tmp/vector-root",
    };
    const vector_identity = try resumeStatusIdentityDigest(alloc, vector_status);
    try std.testing.expectEqualStrings(
        "c0dcafe6ba3af7c4a65883c204f0cee6c94b84f569e925262f5d1f81f69da273",
        &vector_identity,
    );
    const vector_decision_id =
        "resume-status-c0dcafe6ba3af7c4a65883c204f0cee6c94b84f569e925262f5d1f81f69da273";
    const vector_decision_digest = try resumeStatusDecisionDigest(
        alloc,
        vector_status,
        vector_decision_id,
    );
    try std.testing.expectEqualStrings(
        "9e89a9264fbed92094529d255ecc3ae2f8c5aa793dd8ea312d0993bc8f7c18ed",
        &vector_decision_digest,
    );

    var incomplete_store = try session_store.Store.initFromHome(alloc, root, root);
    defer incomplete_store.deinit(alloc);
    const incomplete_path = try session_store.sessionDirPath(
        alloc,
        incomplete_store.sessions_dir,
        conversation_id,
    );
    defer alloc.free(incomplete_path);
    try std.Io.Dir.createDirAbsolute(
        std.testing.io,
        incomplete_path,
        .fromMode(0o700),
    );
    try std.testing.expectError(
        error.SessionStateIncomplete,
        prepared.exactResumeStatus(),
    );
    try std.testing.expectError(
        error.SessionStateIncomplete,
        handleFrame(
            alloc,
            unavailable_request.written(),
            "instance",
            "01234567890123456789012345678901",
        ),
    );
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, incomplete_path);

    var fresh_request = launch_request;
    fresh_request.admission_key = "resume-status-fresh-key";
    fresh_request.launch_id = "resume-status-fresh-launch";
    fresh_request.request_id = "resume-status-fresh-prepare";
    fresh_request.resume_target = .fresh;
    fresh_request.launch_digest = &([_]u8{'0'} ** 64);
    var fresh_digest = try public_protocol.computeLaunchDigest(alloc, fresh_request);
    fresh_request.launch_digest = &fresh_digest;
    var fresh_prepared = try launcher.PreparedLaunch.prepare(alloc, fresh_request);
    defer fresh_prepared.deinit();
    try std.testing.expectError(
        error.LaunchResumeTargetNotExact,
        fresh_prepared.exactResumeStatus(),
    );
    var fresh_status_request = std.Io.Writer.Allocating.init(alloc);
    defer fresh_status_request.deinit();
    try fresh_status_request.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":2,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"resume-fresh\",\"operation\":\"resume_status\",\"state_root\":");
    try writeString(&fresh_status_request.writer, root);
    try fresh_status_request.writer.writeAll(",\"admission_key\":\"resume-status-fresh-key\",\"launch_digest\":");
    try writeString(&fresh_status_request.writer, &fresh_digest);
    try fresh_status_request.writer.writeAll(",\"launch_id\":\"resume-status-fresh-launch\"}");
    try std.testing.expectError(
        error.LaunchResumeTargetNotExact,
        handleFrame(
            alloc,
            fresh_status_request.written(),
            "instance",
            "01234567890123456789012345678901",
        ),
    );

    var mismatch_request = std.Io.Writer.Allocating.init(alloc);
    defer mismatch_request.deinit();
    try mismatch_request.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":2,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"resume-mismatch\",\"operation\":\"resume_status\",\"state_root\":");
    try writeString(&mismatch_request.writer, root);
    try mismatch_request.writer.writeAll(",\"admission_key\":\"resume-status-key\",\"launch_digest\":");
    try writeString(&mismatch_request.writer, &launch_digest);
    try mismatch_request.writer.writeAll(",\"launch_id\":\"wrong-launch\"}");
    try std.testing.expectError(
        error.CorrelationMismatch,
        handleFrame(
            alloc,
            mismatch_request.written(),
            "instance",
            "01234567890123456789012345678901",
        ),
    );

    try createProviderTestConversation(alloc, root, conversation_id);
    var available_request = std.Io.Writer.Allocating.init(alloc);
    defer available_request.deinit();
    try available_request.writer.writeAll("{\"schema_id\":\"fx.private-launch-provider\",\"schema_version\":2,\"instance_id\":\"instance\",\"token\":\"01234567890123456789012345678901\",\"request_id\":\"resume-available\",\"operation\":\"resume_status\",\"state_root\":");
    try writeString(&available_request.writer, root);
    try available_request.writer.writeAll(",\"admission_key\":\"resume-status-key\",\"launch_digest\":");
    try writeString(&available_request.writer, &launch_digest);
    try available_request.writer.writeAll(",\"launch_id\":\"resume-status-launch\"}");
    const available_response = try handleFrame(
        alloc,
        available_request.written(),
        "instance",
        "01234567890123456789012345678901",
    );
    defer alloc.free(available_response);
    var available_json = try std.json.parseFromSlice(std.json.Value, alloc, available_response, .{});
    defer available_json.deinit();
    const available_proof = available_json.value.object.get("result").?.object.get("resume_status").?.object;
    try std.testing.expectEqualStrings("available", try objectString(available_proof, "status"));
    try std.testing.expectEqualStrings(
        "exact_resume_available",
        try objectString(available_proof, "semantic_decision"),
    );
    try std.testing.expectEqualStrings(
        resume_status_authority,
        try objectString(available_proof, "authority"),
    );
    try std.testing.expectEqualStrings(
        conversation_id,
        try objectString(available_proof, "conversation_id"),
    );
    const available_status = try prepared.exactResumeStatus();
    try std.testing.expect(available_status.available);
    const available_decision_id = try objectString(available_proof, "decision_id");
    const available_digest = try resumeStatusDecisionDigest(
        alloc,
        available_status,
        available_decision_id,
    );
    try std.testing.expectEqualStrings(
        &available_digest,
        try objectString(available_proof, "decision_digest"),
    );
    try std.testing.expect(!std.mem.eql(u8, unavailable_id, available_decision_id));

    const conversation_path = try session_store.sessionDirPath(
        alloc,
        incomplete_store.sessions_dir,
        conversation_id,
    );
    defer alloc.free(conversation_path);
    const authority_path = try std.fs.path.join(
        alloc,
        &.{ conversation_path, "authority.json" },
    );
    defer alloc.free(authority_path);
    var authority = try std.Io.Dir.createFileAbsolute(
        std.testing.io,
        authority_path,
        .{ .truncate = true },
    );
    try authority.writeStreamingAll(std.testing.io, "corrupt");
    authority.close(std.testing.io);
    try std.testing.expectError(
        error.InvalidSessionFormat,
        prepared.exactResumeStatus(),
    );
    try std.testing.expectError(
        error.InvalidSessionFormat,
        handleFrame(
            alloc,
            unavailable_request.written(),
            "instance",
            "01234567890123456789012345678901",
        ),
    );
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
