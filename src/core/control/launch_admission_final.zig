const std = @import("std");

pub const schema_id = "fx.launch-admission-final";
pub const schema_version: u16 = 1;
pub const frame_header_bytes: usize = 4;
pub const max_frame_bytes: usize = 1024 * 1024;
pub const max_json_depth: usize = 64;

const Allocator = std.mem.Allocator;

pub const Error = error{
    DuplicateKey,
    EmptyFrame,
    FrameTooLarge,
    InvalidMessage,
    InvalidUtf8,
    MalformedFrame,
    MalformedJson,
    UnsupportedSchema,
    UnsupportedSchemaVersion,
    WriteFailed,
} || Allocator.Error;

pub const Resume = union(enum) {
    fresh,
    exact: []const u8,
};

pub const LaunchRequest = struct {
    admission_key: []const u8,
    conversation_name: []const u8,
    directory: []const u8,
    effort: ?[]const u8 = null,
    initial_work_digest: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    model: ?[]const u8 = null,
    remaining_launch_controls_digest: []const u8,
    request_id: []const u8,
    resume_target: Resume,
    state_root: []const u8,
};

pub const LaunchReceipt = struct {
    admission_key: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    receipt_id: []const u8,
    request_id: []const u8,
};

pub const AdmissionCancelRequest = struct {
    admission_key: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    request_id: []const u8,
};

pub const AdmissionDecisionValue = union(enum) {
    admitted: struct {
        disposition: Disposition,
        turn_id: u64,
    },
    cancelled_before_start: struct {
        cancellation_request_id: []const u8,
    },
};

pub const Disposition = enum {
    queued,
    steering,
};

pub const AdmissionDecision = struct {
    admission_key: []const u8,
    decision: AdmissionDecisionValue,
    launch_digest: []const u8,
    launch_id: []const u8,
    receipt_digest: []const u8,
    receipt_id: []const u8,
};

pub const Outcome = union(enum) {
    exited: u8,
    signalled: u8,
    exec_failed: []const u8,
};

pub const FinalReceipt = struct {
    admission_key: []const u8,
    conversation_id: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    observed_at: []const u8,
    outcome: Outcome,
    receipt_digest: []const u8,
    receipt_id: []const u8,
};

pub const FinalReceiptAcknowledgement = struct {
    acknowledgement_id: []const u8,
    admission_key: []const u8,
    conversation_id: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    receipt_digest: []const u8,
    receipt_id: []const u8,
};

pub const Message = union(enum) {
    launch_request: LaunchRequest,
    launch_receipt: LaunchReceipt,
    admission_cancel_request: AdmissionCancelRequest,
    admission_decision: AdmissionDecision,
    final_receipt: FinalReceipt,
    final_receipt_acknowledgement: FinalReceiptAcknowledgement,
};

pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    message: Message,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ResumeWire = struct {
    conversation_id: ?[]const u8 = null,
    mode: []const u8,
};

const LaunchRequestWire = struct {
    admission_key: []const u8,
    conversation_name: []const u8,
    directory: []const u8,
    effort: ?[]const u8 = null,
    initial_work_digest: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    message_type: []const u8,
    model: ?[]const u8 = null,
    remaining_launch_controls_digest: []const u8,
    request_id: []const u8,
    @"resume": ResumeWire,
    schema_id: []const u8,
    schema_version: u16,
    state_root: []const u8,
};

const LaunchReceiptWire = struct {
    admission_key: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    message_type: []const u8,
    receipt_id: []const u8,
    request_id: []const u8,
    schema_id: []const u8,
    schema_version: u16,
    status: []const u8,
};

const AdmissionCancelRequestWire = struct {
    admission_key: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    message_type: []const u8,
    request_id: []const u8,
    schema_id: []const u8,
    schema_version: u16,
};

const DecisionWire = struct {
    cancellation_request_id: ?[]const u8 = null,
    disposition: ?[]const u8 = null,
    kind: []const u8,
    turn_id: ?[]const u8 = null,
};

const AdmissionDecisionWire = struct {
    admission_key: []const u8,
    decision: DecisionWire,
    launch_digest: []const u8,
    launch_id: []const u8,
    message_type: []const u8,
    receipt_digest: []const u8,
    receipt_id: []const u8,
    schema_id: []const u8,
    schema_version: u16,
};

const OutcomeWire = struct {
    code: ?u8 = null,
    kind: []const u8,
    message: ?[]const u8 = null,
    signal: ?u8 = null,
};

const FinalReceiptWire = struct {
    admission_key: []const u8,
    conversation_id: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    message_type: []const u8,
    observed_at: []const u8,
    outcome: OutcomeWire,
    receipt_digest: []const u8,
    receipt_id: []const u8,
    retained_until_acknowledged: bool,
    schema_id: []const u8,
    schema_version: u16,
};

const FinalReceiptAcknowledgementWire = struct {
    acknowledgement_id: []const u8,
    admission_key: []const u8,
    conversation_id: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    message_type: []const u8,
    receipt_digest: []const u8,
    receipt_id: []const u8,
    schema_id: []const u8,
    schema_version: u16,
};

pub fn decodePayload(alloc: Allocator, payload: []const u8) Error!Decoded {
    if (payload.len == 0) return error.EmptyFrame;
    if (payload.len > max_frame_bytes) return error.FrameTooLarge;
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        scratch,
        payload,
        .{ .allocate = .alloc_always, .parse_numbers = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return error.DuplicateKey,
        else => return error.MalformedJson,
    };
    try validateDepth(value);
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidMessage,
    };
    const parsed_schema = object.get("schema_id") orelse return error.InvalidMessage;
    const parsed_schema_id = switch (parsed_schema) {
        .string => |text| text,
        else => return error.InvalidMessage,
    };
    if (!std.mem.eql(u8, parsed_schema_id, schema_id)) return error.UnsupportedSchema;
    const parsed_version = object.get("schema_version") orelse return error.InvalidMessage;
    if (!jsonNumberEquals(parsed_version, "1")) return error.UnsupportedSchemaVersion;
    const parsed_type = object.get("message_type") orelse return error.InvalidMessage;
    const message_type = switch (parsed_type) {
        .string => |text| text,
        else => return error.InvalidMessage,
    };

    const message = if (std.mem.eql(u8, message_type, "launch_request")) blk: {
        const wire = try parseWire(LaunchRequestWire, scratch, value);
        try validateEnvelope(wire.schema_id, wire.schema_version, wire.message_type, "launch_request");
        const resume_target: Resume = if (std.mem.eql(u8, wire.@"resume".mode, "fresh")) resume_value: {
            if (wire.@"resume".conversation_id != null) return error.InvalidMessage;
            break :resume_value .fresh;
        } else if (std.mem.eql(u8, wire.@"resume".mode, "exact")) resume_value: {
            const id = wire.@"resume".conversation_id orelse return error.InvalidMessage;
            try validateConversationId(id);
            break :resume_value .{ .exact = id };
        } else return error.InvalidMessage;
        const result: LaunchRequest = .{
            .admission_key = wire.admission_key,
            .conversation_name = wire.conversation_name,
            .directory = wire.directory,
            .effort = wire.effort,
            .initial_work_digest = wire.initial_work_digest,
            .launch_digest = wire.launch_digest,
            .launch_id = wire.launch_id,
            .model = wire.model,
            .remaining_launch_controls_digest = wire.remaining_launch_controls_digest,
            .request_id = wire.request_id,
            .resume_target = resume_target,
            .state_root = wire.state_root,
        };
        try validateLaunchRequest(scratch, result);
        break :blk Message{ .launch_request = result };
    } else if (std.mem.eql(u8, message_type, "launch_receipt")) blk: {
        const wire = try parseWire(LaunchReceiptWire, scratch, value);
        try validateEnvelope(wire.schema_id, wire.schema_version, wire.message_type, "launch_receipt");
        if (!std.mem.eql(u8, wire.status, "accepted")) return error.InvalidMessage;
        const result: LaunchReceipt = .{
            .admission_key = wire.admission_key,
            .launch_digest = wire.launch_digest,
            .launch_id = wire.launch_id,
            .receipt_id = wire.receipt_id,
            .request_id = wire.request_id,
        };
        try validateCorrelation(result.admission_key, result.launch_digest, result.launch_id);
        try validateSafeToken(result.receipt_id);
        try validateSafeToken(result.request_id);
        break :blk Message{ .launch_receipt = result };
    } else if (std.mem.eql(u8, message_type, "admission_cancel_request")) blk: {
        const wire = try parseWire(AdmissionCancelRequestWire, scratch, value);
        try validateEnvelope(wire.schema_id, wire.schema_version, wire.message_type, "admission_cancel_request");
        const result: AdmissionCancelRequest = .{
            .admission_key = wire.admission_key,
            .launch_digest = wire.launch_digest,
            .launch_id = wire.launch_id,
            .request_id = wire.request_id,
        };
        try validateCorrelation(result.admission_key, result.launch_digest, result.launch_id);
        try validateSafeToken(result.request_id);
        break :blk Message{ .admission_cancel_request = result };
    } else if (std.mem.eql(u8, message_type, "admission_decision")) blk: {
        const wire = try parseWire(AdmissionDecisionWire, scratch, value);
        try validateEnvelope(wire.schema_id, wire.schema_version, wire.message_type, "admission_decision");
        const decision: AdmissionDecisionValue = if (std.mem.eql(u8, wire.decision.kind, "admitted")) decision: {
            if (wire.decision.cancellation_request_id != null) return error.InvalidMessage;
            const turn_text = wire.decision.turn_id orelse return error.InvalidMessage;
            const disposition_text = wire.decision.disposition orelse return error.InvalidMessage;
            const turn_id = try parsePositiveDecimalU64(turn_text);
            const disposition: Disposition = if (std.mem.eql(u8, disposition_text, "queued"))
                .queued
            else if (std.mem.eql(u8, disposition_text, "steering"))
                .steering
            else
                return error.InvalidMessage;
            break :decision .{ .admitted = .{ .disposition = disposition, .turn_id = turn_id } };
        } else if (std.mem.eql(u8, wire.decision.kind, "cancelled_before_start")) decision: {
            if (wire.decision.disposition != null or wire.decision.turn_id != null) return error.InvalidMessage;
            const request_id = wire.decision.cancellation_request_id orelse return error.InvalidMessage;
            try validateSafeToken(request_id);
            break :decision .{ .cancelled_before_start = .{ .cancellation_request_id = request_id } };
        } else return error.InvalidMessage;
        const result: AdmissionDecision = .{
            .admission_key = wire.admission_key,
            .decision = decision,
            .launch_digest = wire.launch_digest,
            .launch_id = wire.launch_id,
            .receipt_digest = wire.receipt_digest,
            .receipt_id = wire.receipt_id,
        };
        try validateCorrelation(result.admission_key, result.launch_digest, result.launch_id);
        try validateDigest(result.receipt_digest);
        try validateSafeToken(result.receipt_id);
        break :blk Message{ .admission_decision = result };
    } else if (std.mem.eql(u8, message_type, "final_receipt")) blk: {
        const wire = try parseWire(FinalReceiptWire, scratch, value);
        try validateEnvelope(wire.schema_id, wire.schema_version, wire.message_type, "final_receipt");
        if (!wire.retained_until_acknowledged) return error.InvalidMessage;
        const outcome: Outcome = if (std.mem.eql(u8, wire.outcome.kind, "exited")) outcome: {
            if (wire.outcome.message != null or wire.outcome.signal != null) return error.InvalidMessage;
            break :outcome .{ .exited = wire.outcome.code orelse return error.InvalidMessage };
        } else if (std.mem.eql(u8, wire.outcome.kind, "signalled")) outcome: {
            if (wire.outcome.code != null or wire.outcome.message != null) return error.InvalidMessage;
            const signal = wire.outcome.signal orelse return error.InvalidMessage;
            if (signal == 0) return error.InvalidMessage;
            break :outcome .{ .signalled = signal };
        } else if (std.mem.eql(u8, wire.outcome.kind, "exec_failed")) outcome: {
            if (wire.outcome.code != null or wire.outcome.signal != null) return error.InvalidMessage;
            const message = wire.outcome.message orelse return error.InvalidMessage;
            try validateBoundedText(message, 1024);
            break :outcome .{ .exec_failed = message };
        } else return error.InvalidMessage;
        const result: FinalReceipt = .{
            .admission_key = wire.admission_key,
            .conversation_id = wire.conversation_id,
            .launch_digest = wire.launch_digest,
            .launch_id = wire.launch_id,
            .observed_at = wire.observed_at,
            .outcome = outcome,
            .receipt_digest = wire.receipt_digest,
            .receipt_id = wire.receipt_id,
        };
        try validateCorrelation(result.admission_key, result.launch_digest, result.launch_id);
        try validateConversationId(result.conversation_id);
        try validateTimestamp(result.observed_at);
        try validateDigest(result.receipt_digest);
        try validateSafeToken(result.receipt_id);
        break :blk Message{ .final_receipt = result };
    } else if (std.mem.eql(u8, message_type, "final_receipt_acknowledgement")) blk: {
        const wire = try parseWire(FinalReceiptAcknowledgementWire, scratch, value);
        try validateEnvelope(wire.schema_id, wire.schema_version, wire.message_type, "final_receipt_acknowledgement");
        const result: FinalReceiptAcknowledgement = .{
            .acknowledgement_id = wire.acknowledgement_id,
            .admission_key = wire.admission_key,
            .conversation_id = wire.conversation_id,
            .launch_digest = wire.launch_digest,
            .launch_id = wire.launch_id,
            .receipt_digest = wire.receipt_digest,
            .receipt_id = wire.receipt_id,
        };
        try validateSafeToken(result.acknowledgement_id);
        try validateCorrelation(result.admission_key, result.launch_digest, result.launch_id);
        try validateConversationId(result.conversation_id);
        try validateDigest(result.receipt_digest);
        try validateSafeToken(result.receipt_id);
        break :blk Message{ .final_receipt_acknowledgement = result };
    } else return error.InvalidMessage;

    const canonical = try encodePayload(scratch, message);
    if (!std.mem.eql(u8, canonical, payload)) return error.InvalidMessage;
    switch (message) {
        .launch_request => |request| if (!try launchDigestMatches(scratch, request)) return error.InvalidMessage,
        .admission_decision, .final_receipt => if (!try receiptDigestMatches(scratch, message)) return error.InvalidMessage,
        else => {},
    }
    return .{ .arena = arena, .message = message };
}

fn parseWire(comptime T: type, alloc: Allocator, value: std.json.Value) Error!T {
    return std.json.parseFromValueLeaky(T, alloc, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.DuplicateKey,
        else => error.InvalidMessage,
    };
}

fn validateDepth(root: std.json.Value) Error!void {
    const Frame = struct { value: std.json.Value, depth: usize };
    var stack: [max_json_depth + 2]Frame = undefined;
    var len: usize = 1;
    stack[0] = .{ .value = root, .depth = 0 };
    while (len > 0) {
        len -= 1;
        const frame = stack[len];
        if (frame.depth > max_json_depth) return error.InvalidMessage;
        switch (frame.value) {
            .array => |items| for (items.items) |item| {
                if (len == stack.len) return error.InvalidMessage;
                stack[len] = .{ .value = item, .depth = frame.depth + 1 };
                len += 1;
            },
            .object => |object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    if (len == stack.len) return error.InvalidMessage;
                    stack[len] = .{ .value = entry.value_ptr.*, .depth = frame.depth + 1 };
                    len += 1;
                }
            },
            else => {},
        }
    }
}

fn jsonNumberEquals(value: std.json.Value, expected: []const u8) bool {
    return switch (value) {
        .number_string => |text| std.mem.eql(u8, text, expected),
        .integer => |number| number == 1 and std.mem.eql(u8, expected, "1"),
        else => false,
    };
}

fn validateEnvelope(actual_schema: []const u8, version: u16, actual_type: []const u8, expected_type: []const u8) Error!void {
    if (!std.mem.eql(u8, actual_schema, schema_id)) return error.UnsupportedSchema;
    if (version != schema_version) return error.UnsupportedSchemaVersion;
    if (!std.mem.eql(u8, actual_type, expected_type)) return error.InvalidMessage;
}

pub fn validateLaunchRequest(alloc: Allocator, request: LaunchRequest) Error!void {
    try validateCorrelation(request.admission_key, request.launch_digest, request.launch_id);
    try validateBoundedText(request.conversation_name, 240);
    try validateAbsolutePath(alloc, request.directory);
    if (request.effort) |effort| try validateBoundedText(effort, 64);
    try validateDigest(request.initial_work_digest);
    if (request.model) |model| try validateBoundedText(model, 160);
    try validateDigest(request.remaining_launch_controls_digest);
    try validateSafeToken(request.request_id);
    switch (request.resume_target) {
        .fresh => {},
        .exact => |id| try validateConversationId(id),
    }
    try validateAbsolutePath(alloc, request.state_root);
}

pub fn validateMessage(alloc: Allocator, message: Message) Error!void {
    switch (message) {
        .launch_request => |request| {
            try validateLaunchRequest(alloc, request);
            if (!try launchDigestMatches(alloc, request)) return error.InvalidMessage;
        },
        .launch_receipt => |receipt| {
            try validateCorrelation(
                receipt.admission_key,
                receipt.launch_digest,
                receipt.launch_id,
            );
            try validateSafeToken(receipt.receipt_id);
            try validateSafeToken(receipt.request_id);
        },
        .admission_cancel_request => |request| {
            try validateCorrelation(
                request.admission_key,
                request.launch_digest,
                request.launch_id,
            );
            try validateSafeToken(request.request_id);
        },
        .admission_decision => |decision| {
            try validateCorrelation(
                decision.admission_key,
                decision.launch_digest,
                decision.launch_id,
            );
            switch (decision.decision) {
                .admitted => |value| if (value.turn_id == 0) return error.InvalidMessage,
                .cancelled_before_start => |value| try validateSafeToken(
                    value.cancellation_request_id,
                ),
            }
            try validateDigest(decision.receipt_digest);
            try validateSafeToken(decision.receipt_id);
            if (!try receiptDigestMatches(alloc, message)) return error.InvalidMessage;
        },
        .final_receipt => |receipt| {
            try validateCorrelation(
                receipt.admission_key,
                receipt.launch_digest,
                receipt.launch_id,
            );
            try validateConversationId(receipt.conversation_id);
            try validateTimestamp(receipt.observed_at);
            switch (receipt.outcome) {
                .exited => {},
                .signalled => |signal| if (signal == 0) return error.InvalidMessage,
                .exec_failed => |message_text| try validateBoundedText(
                    message_text,
                    1024,
                ),
            }
            try validateDigest(receipt.receipt_digest);
            try validateSafeToken(receipt.receipt_id);
            if (!try receiptDigestMatches(alloc, message)) return error.InvalidMessage;
        },
        .final_receipt_acknowledgement => |acknowledgement| {
            try validateSafeToken(acknowledgement.acknowledgement_id);
            try validateCorrelation(
                acknowledgement.admission_key,
                acknowledgement.launch_digest,
                acknowledgement.launch_id,
            );
            try validateConversationId(acknowledgement.conversation_id);
            try validateDigest(acknowledgement.receipt_digest);
            try validateSafeToken(acknowledgement.receipt_id);
        },
    }
}

pub fn validateCorrelation(admission_key: []const u8, launch_digest: []const u8, launch_id: []const u8) Error!void {
    try validateSafeToken(admission_key);
    try validateDigest(launch_digest);
    try validateSafeToken(launch_id);
}

pub fn validateSafeToken(value: []const u8) Error!void {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return error.InvalidMessage;
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != ':' and byte != '-') {
            return error.InvalidMessage;
        }
    }
}

pub fn validateDigest(value: []const u8) Error!void {
    if (value.len != 64) return error.InvalidMessage;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidMessage;
    }
}

pub fn validateConversationId(value: []const u8) Error!void {
    if (value.len > 256) return error.InvalidMessage;
    try validateSafeToken(value);
}

pub fn validateBoundedText(value: []const u8, maximum_bytes: usize) Error!void {
    if (value.len == 0 or value.len > maximum_bytes or !std.unicode.utf8ValidateSlice(value)) return error.InvalidMessage;
    var non_whitespace = false;
    var index: usize = 0;
    while (index < value.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(value[index]) catch return error.InvalidMessage;
        if (index + sequence_len > value.len) return error.InvalidMessage;
        const codepoint = std.unicode.utf8Decode(value[index .. index + sequence_len]) catch return error.InvalidMessage;
        if ((codepoint <= 0x1f) or (codepoint >= 0x7f and codepoint <= 0x9f)) return error.InvalidMessage;
        if (!std.ascii.isWhitespace(@intCast(if (codepoint <= 0x7f) codepoint else 'x'))) non_whitespace = true;
        index += sequence_len;
    }
    if (!non_whitespace) return error.InvalidMessage;
}

fn validateAbsolutePath(alloc: Allocator, value: []const u8) Error!void {
    try validateBoundedText(value, 4096);
    if (!std.fs.path.isAbsolute(value) or std.mem.eql(u8, value, "/")) return error.InvalidMessage;
    const normalized = std.fs.path.resolve(alloc, &.{value}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer alloc.free(normalized);
    if (!std.mem.eql(u8, normalized, value)) return error.InvalidMessage;
}

fn parsePositiveDecimalU64(text: []const u8) Error!u64 {
    if (text.len == 0 or text[0] == '0') return error.InvalidMessage;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidMessage;
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidMessage;
}

pub fn validateTimestamp(value: []const u8) Error!void {
    if (value.len != 20 and value.len != 24) return error.InvalidMessage;
    const expected = "0000-00-00T00:00:00.000Z";
    for (value, 0..) |byte, index| {
        const marker = expected[index];
        if (std.ascii.isDigit(marker)) {
            if (!std.ascii.isDigit(byte)) return error.InvalidMessage;
        } else if (value.len == 20 and index == 19) {
            if (byte != 'Z') return error.InvalidMessage;
        } else if (byte != marker) return error.InvalidMessage;
    }
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return error.InvalidMessage;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return error.InvalidMessage;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return error.InvalidMessage;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return error.InvalidMessage;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return error.InvalidMessage;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return error.InvalidMessage;
    if (month == 0 or month > 12 or day == 0 or hour > 23 or minute > 59 or second > 59) return error.InvalidMessage;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const days_in_month = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > days_in_month[month - 1]) return error.InvalidMessage;
}

pub fn encodePayload(alloc: Allocator, message: Message) Error![]u8 {
    try validateMessage(alloc, message);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeMessage(&out.writer, message, true);
    if (out.written().len == 0 or out.written().len > max_frame_bytes) return error.FrameTooLarge;
    return out.toOwnedSlice();
}

pub fn encodeFrame(alloc: Allocator, message: Message) Error![]u8 {
    const payload = try encodePayload(alloc, message);
    defer alloc.free(payload);
    const frame = try alloc.alloc(u8, frame_header_bytes + payload.len);
    std.mem.writeInt(u32, frame[0..4], @intCast(payload.len), .big);
    @memcpy(frame[4..], payload);
    return frame;
}

pub fn decodeFrameExact(frame: []const u8) Error![]const u8 {
    if (frame.len < frame_header_bytes) return error.MalformedFrame;
    const announced = std.mem.readInt(u32, frame[0..4], .big);
    if (announced == 0) return error.EmptyFrame;
    if (announced > max_frame_bytes) return error.FrameTooLarge;
    if (frame.len != frame_header_bytes + announced) return error.MalformedFrame;
    return frame[frame_header_bytes..];
}

fn writeMessage(writer: *std.Io.Writer, message: Message, include_receipt_digest: bool) !void {
    switch (message) {
        .launch_request => |value| {
            try writer.writeAll("{\"admission_key\":");
            try writeString(writer, value.admission_key);
            try writer.writeAll(",\"conversation_name\":");
            try writeString(writer, value.conversation_name);
            try writer.writeAll(",\"directory\":");
            try writeString(writer, value.directory);
            if (value.effort) |effort| {
                try writer.writeAll(",\"effort\":");
                try writeString(writer, effort);
            }
            try writer.writeAll(",\"initial_work_digest\":");
            try writeString(writer, value.initial_work_digest);
            try writer.writeAll(",\"launch_digest\":");
            try writeString(writer, value.launch_digest);
            try writer.writeAll(",\"launch_id\":");
            try writeString(writer, value.launch_id);
            try writer.writeAll(",\"message_type\":\"launch_request\"");
            if (value.model) |model| {
                try writer.writeAll(",\"model\":");
                try writeString(writer, model);
            }
            try writer.writeAll(",\"remaining_launch_controls_digest\":");
            try writeString(writer, value.remaining_launch_controls_digest);
            try writer.writeAll(",\"request_id\":");
            try writeString(writer, value.request_id);
            try writer.writeAll(",\"resume\":");
            switch (value.resume_target) {
                .fresh => try writer.writeAll("{\"mode\":\"fresh\"}"),
                .exact => |conversation_id| {
                    try writer.writeAll("{\"conversation_id\":");
                    try writeString(writer, conversation_id);
                    try writer.writeAll(",\"mode\":\"exact\"}");
                },
            }
            try writeEnvelopeTail(writer, "launch_request");
            try writer.writeAll(",\"state_root\":");
            try writeString(writer, value.state_root);
            try writer.writeByte('}');
        },
        .launch_receipt => |value| {
            try writer.writeAll("{\"admission_key\":");
            try writeString(writer, value.admission_key);
            try writeCorrelation(writer, value.launch_digest, value.launch_id);
            try writer.writeAll(",\"message_type\":\"launch_receipt\",\"receipt_id\":");
            try writeString(writer, value.receipt_id);
            try writer.writeAll(",\"request_id\":");
            try writeString(writer, value.request_id);
            try writeSchemaTail(writer);
            try writer.writeAll(",\"status\":\"accepted\"}");
        },
        .admission_cancel_request => |value| {
            try writer.writeAll("{\"admission_key\":");
            try writeString(writer, value.admission_key);
            try writeCorrelation(writer, value.launch_digest, value.launch_id);
            try writer.writeAll(",\"message_type\":\"admission_cancel_request\",\"request_id\":");
            try writeString(writer, value.request_id);
            try writeSchemaTail(writer);
            try writer.writeByte('}');
        },
        .admission_decision => |value| {
            try writer.writeAll("{\"admission_key\":");
            try writeString(writer, value.admission_key);
            try writer.writeAll(",\"decision\":");
            switch (value.decision) {
                .admitted => |decision| {
                    try writer.writeAll("{\"disposition\":");
                    try writeString(writer, @tagName(decision.disposition));
                    try writer.writeAll(",\"kind\":\"admitted\",\"turn_id\":\"");
                    try writer.print("{d}", .{decision.turn_id});
                    try writer.writeAll("\"}");
                },
                .cancelled_before_start => |decision| {
                    try writer.writeAll("{\"cancellation_request_id\":");
                    try writeString(writer, decision.cancellation_request_id);
                    try writer.writeAll(",\"kind\":\"cancelled_before_start\"}");
                },
            }
            try writeCorrelation(writer, value.launch_digest, value.launch_id);
            try writer.writeAll(",\"message_type\":\"admission_decision\"");
            if (include_receipt_digest) {
                try writer.writeAll(",\"receipt_digest\":");
                try writeString(writer, value.receipt_digest);
            }
            try writer.writeAll(",\"receipt_id\":");
            try writeString(writer, value.receipt_id);
            try writeSchemaTail(writer);
            try writer.writeByte('}');
        },
        .final_receipt => |value| {
            try writer.writeAll("{\"admission_key\":");
            try writeString(writer, value.admission_key);
            try writer.writeAll(",\"conversation_id\":");
            try writeString(writer, value.conversation_id);
            try writeCorrelation(writer, value.launch_digest, value.launch_id);
            try writer.writeAll(",\"message_type\":\"final_receipt\",\"observed_at\":");
            try writeString(writer, value.observed_at);
            try writer.writeAll(",\"outcome\":");
            switch (value.outcome) {
                .exited => |code| try writer.print("{{\"code\":{d},\"kind\":\"exited\"}}", .{code}),
                .signalled => |signal| try writer.print("{{\"kind\":\"signalled\",\"signal\":{d}}}", .{signal}),
                .exec_failed => |failure| {
                    try writer.writeAll("{\"kind\":\"exec_failed\",\"message\":");
                    try writeString(writer, failure);
                    try writer.writeByte('}');
                },
            }
            if (include_receipt_digest) {
                try writer.writeAll(",\"receipt_digest\":");
                try writeString(writer, value.receipt_digest);
            }
            try writer.writeAll(",\"receipt_id\":");
            try writeString(writer, value.receipt_id);
            try writer.writeAll(",\"retained_until_acknowledged\":true");
            try writeSchemaTail(writer);
            try writer.writeByte('}');
        },
        .final_receipt_acknowledgement => |value| {
            try writer.writeAll("{\"acknowledgement_id\":");
            try writeString(writer, value.acknowledgement_id);
            try writer.writeAll(",\"admission_key\":");
            try writeString(writer, value.admission_key);
            try writer.writeAll(",\"conversation_id\":");
            try writeString(writer, value.conversation_id);
            try writeCorrelation(writer, value.launch_digest, value.launch_id);
            try writer.writeAll(",\"message_type\":\"final_receipt_acknowledgement\",\"receipt_digest\":");
            try writeString(writer, value.receipt_digest);
            try writer.writeAll(",\"receipt_id\":");
            try writeString(writer, value.receipt_id);
            try writeSchemaTail(writer);
            try writer.writeByte('}');
        },
    }
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeCorrelation(writer: *std.Io.Writer, launch_digest: []const u8, launch_id: []const u8) !void {
    try writer.writeAll(",\"launch_digest\":");
    try writeString(writer, launch_digest);
    try writer.writeAll(",\"launch_id\":");
    try writeString(writer, launch_id);
}

fn writeEnvelopeTail(writer: *std.Io.Writer, _: []const u8) !void {
    try writeSchemaTail(writer);
}

fn writeSchemaTail(writer: *std.Io.Writer) !void {
    try writer.writeAll(",\"schema_id\":\"fx.launch-admission-final\",\"schema_version\":1");
}

pub fn computeLaunchDigest(alloc: Allocator, request: LaunchRequest) Error![64]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"admission_key\":");
    try writeString(&out.writer, request.admission_key);
    try out.writer.writeAll(",\"conversation_name\":");
    try writeString(&out.writer, request.conversation_name);
    try out.writer.writeAll(",\"directory\":");
    try writeString(&out.writer, request.directory);
    if (request.effort) |effort| {
        try out.writer.writeAll(",\"effort\":");
        try writeString(&out.writer, effort);
    }
    try out.writer.writeAll(",\"initial_work_digest\":");
    try writeString(&out.writer, request.initial_work_digest);
    try out.writer.writeAll(",\"launch_id\":");
    try writeString(&out.writer, request.launch_id);
    if (request.model) |model| {
        try out.writer.writeAll(",\"model\":");
        try writeString(&out.writer, model);
    }
    try out.writer.writeAll(",\"remaining_launch_controls_digest\":");
    try writeString(&out.writer, request.remaining_launch_controls_digest);
    try out.writer.writeAll(",\"resume\":");
    switch (request.resume_target) {
        .fresh => try out.writer.writeAll("{\"mode\":\"fresh\"}"),
        .exact => |conversation_id| {
            try out.writer.writeAll("{\"conversation_id\":");
            try writeString(&out.writer, conversation_id);
            try out.writer.writeAll(",\"mode\":\"exact\"}");
        },
    }
    try out.writer.writeAll(",\"state_root\":");
    try writeString(&out.writer, request.state_root);
    try out.writer.writeByte('}');
    return sha256Hex(out.written());
}

pub fn launchDigestMatches(alloc: Allocator, request: LaunchRequest) Error!bool {
    const digest = try computeLaunchDigest(alloc, request);
    return std.mem.eql(u8, &digest, request.launch_digest);
}

pub fn computeReceiptDigest(alloc: Allocator, message: Message) Error![64]u8 {
    switch (message) {
        .admission_decision, .final_receipt => {},
        else => return error.InvalidMessage,
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeMessage(&out.writer, message, false);
    return sha256Hex(out.written());
}

pub fn receiptDigestMatches(alloc: Allocator, message: Message) Error!bool {
    const recorded = switch (message) {
        .admission_decision => |value| value.receipt_digest,
        .final_receipt => |value| value.receipt_digest,
        else => return error.InvalidMessage,
    };
    const digest = try computeReceiptDigest(alloc, message);
    return std.mem.eql(u8, &digest, recorded);
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn formatTimestamp(buffer: *[24]u8, timestamp_ms: i64) Error![]const u8 {
    if (timestamp_ms < 0 or timestamp_ms > 253_402_300_799_999) return error.InvalidMessage;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(timestamp_ms, std.time.ms_per_s)) };
    const day = seconds.getDaySeconds();
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const milliseconds: u10 = @intCast(@mod(timestamp_ms, std.time.ms_per_s));
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
        milliseconds,
    }) catch return error.InvalidMessage;
}

test "launch admission final timestamp formatter emits strict UTC milliseconds" {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.000Z",
        try formatTimestamp(&buffer, 0),
    );
}

test "launch admission final strict golden codec matches frozen schema v1 fixture" {
    const alloc = std.testing.allocator;
    const fixture = @embedFile("fixtures/launch_admission_final_v1.jsonl");
    try std.testing.expectEqual(@as(usize, 4262), fixture.len);
    const fixture_digest = sha256Hex(fixture);
    try std.testing.expectEqualStrings("b807e31bf8f4de4179b91cca4c9f3a9a40d572f98d8e5467242fc70908eb8161", &fixture_digest);

    var lines = std.mem.splitScalar(u8, fixture, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var decoded = try decodePayload(alloc, line);
        defer decoded.deinit();
        const encoded = try encodePayload(alloc, decoded.message);
        defer alloc.free(encoded);
        try std.testing.expectEqualStrings(line, encoded);
        const frame = try encodeFrame(alloc, decoded.message);
        defer alloc.free(frame);
        try std.testing.expectEqualStrings(line, try decodeFrameExact(frame));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), count);
}

test "launch admission final strict codec rejects noncanonical and malformed boundaries" {
    const alloc = std.testing.allocator;
    const canonical = "{\"admission_key\":\"key\",\"launch_digest\":\"2736dca2463e0a9c5fbfa857d2a74dccc2eac704ddbbbc8b0e3433ae72549ac5\",\"launch_id\":\"launch\",\"message_type\":\"admission_cancel_request\",\"request_id\":\"cancel\",\"schema_id\":\"fx.launch-admission-final\",\"schema_version\":1}";
    var decoded = try decodePayload(alloc, canonical);
    decoded.deinit();
    try std.testing.expectError(error.InvalidMessage, decodePayload(alloc, " {\"admission_key\":\"key\",\"launch_digest\":\"2736dca2463e0a9c5fbfa857d2a74dccc2eac704ddbbbc8b0e3433ae72549ac5\",\"launch_id\":\"launch\",\"message_type\":\"admission_cancel_request\",\"request_id\":\"cancel\",\"schema_id\":\"fx.launch-admission-final\",\"schema_version\":1}"));
    try std.testing.expectError(error.DuplicateKey, decodePayload(alloc, "{\"schema_id\":\"fx.launch-admission-final\",\"schema_id\":\"fx.launch-admission-final\",\"schema_version\":1,\"message_type\":\"admission_cancel_request\"}"));
    try std.testing.expectError(error.InvalidUtf8, decodePayload(alloc, &.{ 0xff, 0xfe }));
    try std.testing.expectError(error.MalformedFrame, decodeFrameExact(&.{ 0, 0, 0 }));
    try std.testing.expectError(error.EmptyFrame, decodeFrameExact(&.{ 0, 0, 0, 0 }));
    try std.testing.expectError(error.FrameTooLarge, decodeFrameExact(&.{ 0, 16, 0, 1 }));
    try std.testing.expectError(error.MalformedFrame, decodeFrameExact(&.{ 0, 0, 0, 2, '{' }));
    try std.testing.expectError(error.MalformedFrame, decodeFrameExact(&.{ 0, 0, 0, 1, '{', '}' }));

    try std.testing.expectError(error.InvalidMessage, encodePayload(alloc, .{
        .admission_cancel_request = .{
            .admission_key = "key",
            .launch_digest = "2736dca2463e0a9c5fbfa857d2a74dccc2eac704ddbbbc8b0e3433ae72549ac5",
            .launch_id = "launch",
            .request_id = "invalid request id",
        },
    }));
}

test "launch admission final digest helpers reproduce frozen launch and receipt authorities" {
    const alloc = std.testing.allocator;
    const fixture = @embedFile("fixtures/launch_admission_final_v1.jsonl");
    var lines = std.mem.splitScalar(u8, fixture, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var decoded = try decodePayload(alloc, line);
        defer decoded.deinit();
        switch (decoded.message) {
            .launch_request => |request| try std.testing.expect(try launchDigestMatches(alloc, request)),
            .admission_decision, .final_receipt => try std.testing.expect(try receiptDigestMatches(alloc, decoded.message)),
            else => {},
        }
    }
}
