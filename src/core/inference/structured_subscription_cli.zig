const std = @import("std");
const structured = @import("structured_subscription.zig");

const Allocator = std.mem.Allocator;

pub const max_frame_bytes: usize = 1024 * 1024;

pub const Options = struct {
    state_root: []const u8,
};

pub const InvocationResult = struct {
    frame: []u8,
    exit_code: u8,

    pub fn deinit(self: *InvocationResult, alloc: Allocator) void {
        alloc.free(self.frame);
        self.* = undefined;
    }
};

pub fn parseOptions(
    args: []const [:0]const u8,
    default_state_root: []const u8,
) !Options {
    if (args.len == 0) return .{ .state_root = default_state_root };
    if (args.len != 2 or !std.mem.eql(u8, args[0], "--state-root")) {
        return error.InvalidStructuredInferenceArgs;
    }
    if (!std.fs.path.isAbsolute(args[1])) return error.InvalidStructuredInferenceStateRoot;
    return .{ .state_root = args[1] };
}

/// Runs one already-bounded frame. The caller owns the returned JSON bytes.
pub fn runFrame(
    alloc: Allocator,
    input: []const u8,
    state_root: []const u8,
    dependencies: structured.Dependencies,
) !InvocationResult {
    const line = extractSingleFrame(input) catch |err| return protocolErrorResult(alloc, @errorName(err));
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{ .parse_numbers = false }) catch
        return protocolErrorResult(alloc, "InvalidStructuredInferenceJson");
    defer parsed.deinit();
    if (parsed.value != .object) return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
    const object = parsed.value.object;
    if (!validEnvelope(object)) return protocolErrorResult(alloc, "InvalidStructuredInferenceEnvelope");
    const operation = objectString(object, "operation") catch
        return protocolErrorResult(alloc, "InvalidStructuredInferenceOperation");

    if (std.mem.eql(u8, operation, "infer")) {
        if (object.count() != 9) return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        const model = objectString(object, "model") catch
            return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        const effort = objectString(object, "effort") catch
            return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        const prompt = objectString(object, "prompt") catch
            return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        const caller_key = objectString(object, "caller_key") catch
            return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        const schema = object.get("schema") orelse
            return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        const cancelled_value = object.get("cancelled") orelse
            return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        if (cancelled_value != .bool) return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        var cancel_flag = std.atomic.Value(bool).init(cancelled_value.bool);
        const frame = structured.infer(alloc, state_root, .{
            .model = model,
            .effort = effort,
            .prompt = prompt,
            .schema = schema,
            .caller_key = caller_key,
            .cancel_flag = &cancel_flag,
        }, dependencies) catch |err| switch (err) {
            error.OutOfMemory, error.NoSpaceLeft, error.DiskQuota => return err,
            else => return protocolErrorResult(alloc, @errorName(err)),
        };
        return .{ .frame = frame, .exit_code = 0 };
    }
    if (std.mem.eql(u8, operation, "ack")) {
        if (object.count() != 5) return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        const caller_key = objectString(object, "caller_key") catch
            return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        const receipt_id = objectString(object, "receipt_id") catch
            return protocolErrorResult(alloc, "InvalidStructuredInferenceFrame");
        const frame = structured.acknowledge(
            alloc,
            state_root,
            caller_key,
            receipt_id,
        ) catch |err| switch (err) {
            error.OutOfMemory, error.NoSpaceLeft, error.DiskQuota => return err,
            else => return protocolErrorResult(alloc, @errorName(err)),
        };
        return .{ .frame = frame, .exit_code = 0 };
    }
    return protocolErrorResult(alloc, "InvalidStructuredInferenceOperation");
}

fn extractSingleFrame(input: []const u8) ![]const u8 {
    if (input.len == 0 or input.len > max_frame_bytes) return error.StructuredInferenceFrameSizeInvalid;
    if (input[input.len - 1] != '\n') return error.StructuredInferenceFrameMissingNewline;
    var frame = input[0 .. input.len - 1];
    if (frame.len > 0 and frame[frame.len - 1] == '\r') frame = frame[0 .. frame.len - 1];
    if (frame.len == 0 or std.mem.findScalar(u8, frame, '\n') != null or
        std.mem.findScalar(u8, frame, '\r') != null)
    {
        return error.StructuredInferenceMultipleFrames;
    }
    return frame;
}

fn validEnvelope(object: std.json.ObjectMap) bool {
    const id = object.get("schema_id") orelse return false;
    if (id != .string or !std.mem.eql(u8, id.string, structured.schema_id)) return false;
    const version = object.get("version") orelse return false;
    if (version != .number_string or !std.mem.eql(u8, version.number_string, "1")) return false;
    return true;
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidStructuredInferenceFrame;
    if (value != .string) return error.InvalidStructuredInferenceFrame;
    return value.string;
}

pub fn protocolErrorResult(alloc: Allocator, code: []const u8) !InvocationResult {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema_id\":");
    try std.json.Stringify.value(structured.schema_id, .{}, &out.writer);
    try out.writer.print(",\"version\":{d},\"operation\":\"error\",\"code\":", .{structured.wire_version});
    try std.json.Stringify.value(code, .{}, &out.writer);
    try out.writer.writeByte('}');
    return .{ .frame = try out.toOwnedSlice(), .exit_code = 2 };
}

test "structured subscription CLI accepts one strict versioned inference frame" {
    const frame =
        \\{"schema_id":"fx.structured-subscription-inference","version":1,"operation":"infer","model":"gpt-test","effort":"high","prompt":"prompt","schema":{"type":"object","properties":{},"required":[],"additionalProperties":false},"caller_key":"key","cancelled":false}
        \\
    ;
    const extracted = try extractSingleFrame(frame);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        extracted,
        .{ .parse_numbers = false },
    );
    defer parsed.deinit();
    try std.testing.expect(validEnvelope(parsed.value.object));
    try std.testing.expectEqualStrings("infer", try objectString(parsed.value.object, "operation"));
}

test "structured subscription CLI rejects multiple missing-newline and oversized frames" {
    try std.testing.expectError(
        error.StructuredInferenceMultipleFrames,
        extractSingleFrame("{}\n{}\n"),
    );
    try std.testing.expectError(
        error.StructuredInferenceFrameMissingNewline,
        extractSingleFrame("{}"),
    );
    const oversized = try std.testing.allocator.alloc(u8, max_frame_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.StructuredInferenceFrameSizeInvalid,
        extractSingleFrame(oversized),
    );
}
