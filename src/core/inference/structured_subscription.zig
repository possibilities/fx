const std = @import("std");
const credential_authority = @import("../auth/credential_authority.zig");
const credentials = @import("../auth/credentials.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const stream_provider = @import("../agent/stream_provider.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const ledger = @import("structured_receipt_ledger.zig");
const schema_validator = @import("structured_schema.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema_id = "fx.structured-subscription-inference";
pub const wire_version: u32 = 1;
pub const response_format_name = "fx_structured_subscription_inference_v1";
pub const max_prompt_bytes: usize = 512 * 1024;
const terminal_frame_overhead_reserve: usize = 64 * 1024;
pub const max_provider_output_bytes: usize = ledger.max_terminal_frame_bytes - terminal_frame_overhead_reserve;
pub const max_provider_response_id_bytes: usize = 4096;
pub const provider_deadline_ms: i64 = 60_000;

pub const Request = struct {
    model: []const u8,
    effort: []const u8,
    prompt: []const u8,
    schema: std.json.Value,
    caller_key: []const u8,
    cancel_flag: *std.atomic.Value(bool),
};

pub const CredentialProvider = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (?*anyopaque, Allocator) anyerror!?credentials.Credential,

    /// Returns an owned credential when present.
    pub fn resolve(self: CredentialProvider, alloc: Allocator) !?credentials.Credential {
        return self.resolve_fn(self.context, alloc);
    }
};

pub const Dependencies = struct {
    credential: CredentialProvider,
    catalog: model_catalog.Provider,
    responses: stream_provider.Provider,
    catalog_client_version: []const u8,
    provider_protocol: []const u8,
};

const Status = enum {
    succeeded,
    refused,
    cancelled,
    provider_failed,
    schema_failed,
};

const Failure = struct {
    stage: []const u8,
    code: []const u8,
    retryable: bool = false,
};

const Provenance = struct {
    credential_source: ?credentials.Source = null,
    credential_identity: ?credential_authority.Identity = null,
    model: []const u8,
    effort: []const u8,
    effort_index: ?usize = null,
    catalog_selection_digest: ?[Sha256.digest_length]u8 = null,
    catalog_client_version: []const u8,
    provider_protocol: []const u8,
    provider_response_id: ?[]const u8 = null,
};

/// Executes one tool-free structured request and returns one owned terminal
/// JSON frame. Same-key/same-request calls return the exact persisted bytes.
pub fn infer(
    alloc: Allocator,
    state_root: []const u8,
    request: Request,
    dependencies: Dependencies,
) ![]u8 {
    const canonical_schema = try schema_validator.canonicalStringify(alloc, request.schema);
    defer alloc.free(canonical_schema);
    const request_digest = requestDigest(request.model, request.effort, request.prompt, canonical_schema);

    var store = try ledger.Store.init(state_root);
    defer store.deinit();
    var entry = try store.lock(alloc, request.caller_key);
    defer entry.deinit();

    var existing = try entry.load();
    defer if (existing) |*record| record.deinit(alloc);
    if (existing) |record| {
        if (!std.mem.eql(u8, &record.request_digest, &request_digest)) {
            return error.StructuredInferenceCallerKeyConflict;
        }
        switch (record.phase) {
            .terminal => return alloc.dupe(u8, record.terminal_frame.?),
            .provider_admitted => {
                return terminalize(
                    alloc,
                    &entry,
                    request_digest,
                    .provider_failed,
                    null,
                    .{ .stage = "recovery", .code = "provider_outcome_unknown", .retryable = false },
                    .{
                        .model = request.model,
                        .effort = request.effort,
                        .catalog_client_version = dependencies.catalog_client_version,
                        .provider_protocol = dependencies.provider_protocol,
                    },
                );
            },
            .started => {},
        }
    } else {
        try entry.save(.{ .request_digest = request_digest, .phase = .started });
    }

    var provenance = Provenance{
        .model = request.model,
        .effort = request.effort,
        .catalog_client_version = dependencies.catalog_client_version,
        .provider_protocol = dependencies.provider_protocol,
    };

    validateRequest(request) catch |err| {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .schema_failed,
            null,
            .{ .stage = "request", .code = @errorName(err) },
            provenance,
        );
    };
    if (request.cancel_flag.load(.seq_cst)) {
        return terminalizeCancelled(alloc, &entry, request_digest, "before_credential", provenance);
    }

    var credential = dependencies.credential.resolve(alloc) catch |err| switch (err) {
        error.OutOfMemory, error.NoSpaceLeft, error.DiskQuota => return err,
        else => return terminalize(
            alloc,
            &entry,
            request_digest,
            .provider_failed,
            null,
            .{ .stage = "credential", .code = "credential_resolution_failed" },
            provenance,
        ),
    } orelse return terminalize(
        alloc,
        &entry,
        request_digest,
        .provider_failed,
        null,
        .{ .stage = "credential", .code = "codex_subscription_credential_unavailable" },
        provenance,
    );
    defer credential.deinit(alloc);
    if (credential.source != .chatgpt_subscription) {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .provider_failed,
            null,
            .{ .stage = "credential", .code = "wrong_credential_source" },
            provenance,
        );
    }
    provenance.credential_source = credential.source;
    provenance.credential_identity = credential_authority.derive(
        credential.source,
        credential.accountId(),
    ) orelse return terminalize(
        alloc,
        &entry,
        request_digest,
        .provider_failed,
        null,
        .{ .stage = "credential", .code = "credential_identity_unavailable" },
        provenance,
    );
    if (request.cancel_flag.load(.seq_cst)) {
        return terminalizeCancelled(alloc, &entry, request_digest, "before_catalog", provenance);
    }

    const catalog_result = dependencies.catalog.fetch(alloc, .{
        .access = credentials.catalogAccessAt(credential, io_mod.milliTimestamp()),
        .endpoint = "",
        .cancel_flag = request.cancel_flag,
        .view = .full,
    }) catch |err| return err;
    var catalog = switch (catalog_result) {
        .catalog => |owned| owned,
        .failure => |failure| {
            if (failure.category == .cancellation) {
                return terminalizeCancelled(alloc, &entry, request_digest, "catalog", provenance);
            }
            return terminalize(
                alloc,
                &entry,
                request_digest,
                .provider_failed,
                null,
                .{
                    .stage = "catalog",
                    .code = catalogFailureCode(failure.category),
                    .retryable = failure.retryable,
                },
                provenance,
            );
        },
    };
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    const selection = selectExactPair(catalog.items, request.model, request.effort) orelse
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .provider_failed,
            null,
            .{ .stage = "catalog", .code = "exact_model_effort_pair_unavailable" },
            provenance,
        );
    provenance.effort_index = selection.effort_index;
    provenance.catalog_selection_digest = catalogSelectionDigest(
        selection.entry,
        selection.effort_index,
    );
    if (request.cancel_flag.load(.seq_cst)) {
        return terminalizeCancelled(alloc, &entry, request_digest, "before_provider_admission", provenance);
    }

    const cancellation_frame = try buildTerminalFrame(
        alloc,
        request_digest,
        .cancelled,
        null,
        .{ .stage = "cancellation", .code = "before_provider_admission" },
        provenance,
    );
    defer alloc.free(cancellation_frame);

    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var admission_context = AdmissionContext{
        .entry = &entry,
        .request_digest = request_digest,
        .cancel_flag = request.cancel_flag,
        .cancellation_frame = cancellation_frame,
        .attempt_evidence = &attempt_evidence,
    };
    var delivery = stream_provider.DeliveryCertainty.init();
    var event_capture = EventCapture{};
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = request.prompt }};
    var provider_result = dependencies.responses.stream(alloc, .{
        .credential = .{ .direct = .{
            .secret_bytes = credential.token,
            .source = credential.source,
            .account_id = credential.accountId(),
        } },
        .session_id = null,
        .model = request.model,
        .retry_count = 1,
        .messages = &messages,
        .tools = .{},
        .tool_choice = .none,
        .vision_mode = .unavailable,
        .provider_options = .{ .reasoning = selection.effort },
        .response_format = .{
            .name = response_format_name,
            .description = "Return one value matching the caller's strict object schema.",
            .schema = request.schema,
        },
        .trace_ctx = .{},
        .content_capture_limit = max_provider_output_bytes,
        .deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(provider_deadline_ms),
        }),
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .events = .{ .context = &event_capture, .emit_fn = EventCapture.emit },
        .admission = .{ .context = &admission_context, .admit_fn = AdmissionContext.admit },
        .cancel_flag = request.cancel_flag,
        .provider_attempt_owner = .transport,
    }) catch |err| {
        if (admission_context.cancelled_terminal_saved) {
            return alloc.dupe(u8, cancellation_frame);
        }
        if (err == error.OutOfMemory or err == error.NoSpaceLeft or err == error.DiskQuota) return err;
        return terminalize(
            alloc,
            &entry,
            request_digest,
            if (err == error.Cancelled) .cancelled else .provider_failed,
            null,
            if (err == error.Cancelled)
                .{ .stage = "cancellation", .code = if (admission_context.admitted) "after_provider_admission" else "before_provider_admission" }
            else
                .{ .stage = "provider", .code = providerErrorCode(err), .retryable = delivery.load() == .definitely_unsent },
            provenance,
        );
    };
    defer provider_result.deinit(alloc);

    if (!admission_context.admitted or !attempt_evidence.provider_admitted) {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .provider_failed,
            null,
            .{ .stage = "provider", .code = "provider_admission_missing" },
            provenance,
        );
    }
    if (event_capture.saw_tool_event) {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .provider_failed,
            null,
            .{ .stage = "provider", .code = "unexpected_tool_event" },
            provenance,
        );
    }

    const completion = switch (provider_result) {
        .failed => |failure| return terminalize(
            alloc,
            &entry,
            request_digest,
            .provider_failed,
            null,
            .{
                .stage = "provider",
                .code = providerFailureCode(failure.kind),
                .retryable = providerFailureRetryable(failure.kind),
            },
            provenance,
        ),
        .completed => |completed| completed.completion,
    };
    if (completion.generation_id) |response_id| {
        if (response_id.len == 0 or response_id.len > max_provider_response_id_bytes) {
            return terminalize(
                alloc,
                &entry,
                request_digest,
                .provider_failed,
                null,
                .{ .stage = "provider", .code = "provider_response_id_size_invalid" },
                provenance,
            );
        }
        provenance.provider_response_id = response_id;
    }
    if (completion.tool_calls.len != 0) {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .provider_failed,
            null,
            .{ .stage = "provider", .code = "unexpected_tool_call" },
            provenance,
        );
    }
    if (completion.finish_reason == .content_filter) {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .refused,
            null,
            .{ .stage = "provider", .code = "refusal" },
            provenance,
        );
    }
    if (completion.finish_reason != null and completion.finish_reason != .stop) {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .provider_failed,
            null,
            .{ .stage = "provider", .code = "non_terminal_success_finish_reason" },
            provenance,
        );
    }

    if (completion.content_capture_overflowed) {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .schema_failed,
            null,
            .{ .stage = "response_schema", .code = "structured_output_size_invalid" },
            provenance,
        );
    }

    const content = completion.content orelse return terminalize(
        alloc,
        &entry,
        request_digest,
        .schema_failed,
        null,
        .{ .stage = "response_schema", .code = "missing_structured_output" },
        provenance,
    );
    if (content.len == 0 or content.len > max_provider_output_bytes) {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .schema_failed,
            null,
            .{ .stage = "response_schema", .code = "structured_output_size_invalid" },
            provenance,
        );
    }
    var parsed_output = std.json.parseFromSlice(std.json.Value, alloc, content, .{ .parse_numbers = false }) catch
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .schema_failed,
            null,
            .{ .stage = "response_schema", .code = "structured_output_invalid_json" },
            provenance,
        );
    defer parsed_output.deinit();
    schema_validator.validateValue(request.schema, parsed_output.value, .{}) catch |err| {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .schema_failed,
            null,
            .{ .stage = "response_schema", .code = @errorName(err) },
            provenance,
        );
    };
    const canonical_output = try schema_validator.canonicalStringify(alloc, parsed_output.value);
    defer alloc.free(canonical_output);
    if (canonical_output.len > max_provider_output_bytes) {
        return terminalize(
            alloc,
            &entry,
            request_digest,
            .schema_failed,
            null,
            .{ .stage = "response_schema", .code = "structured_output_size_invalid" },
            provenance,
        );
    }
    return terminalize(
        alloc,
        &entry,
        request_digest,
        .succeeded,
        canonical_output,
        null,
        provenance,
    );
}

/// Persists acknowledgement and returns one owned, stable acknowledgement
/// frame. Repeating the same acknowledgement produces identical bytes.
pub fn acknowledge(
    alloc: Allocator,
    state_root: []const u8,
    caller_key: []const u8,
    receipt_id: []const u8,
) ![]u8 {
    if (receipt_id.len != Sha256.digest_length * 2) return error.InvalidStructuredInferenceReceipt;
    var store = try ledger.Store.init(state_root);
    defer store.deinit();
    var entry = try store.lock(alloc, caller_key);
    defer entry.deinit();
    var record = (try entry.load()) orelse return error.StructuredInferenceReceiptNotFound;
    defer record.deinit(alloc);
    if (record.phase != .terminal) return error.StructuredInferenceReceiptNotTerminal;
    const persisted_receipt = try receiptIdFromFrame(alloc, record.terminal_frame.?);
    defer alloc.free(persisted_receipt);
    if (!std.mem.eql(u8, persisted_receipt, receipt_id)) {
        return error.InvalidStructuredInferenceReceipt;
    }
    if (!record.acknowledged) {
        record.acknowledged = true;
        try entry.save(record);
    }
    return buildAckFrame(alloc, receipt_id);
}

const Selection = struct {
    entry: model_catalog.ModelCatalogEntry,
    effort: types.ReasoningEffort,
    effort_index: usize,
};

fn selectExactPair(
    catalog: []const model_catalog.ModelCatalogEntry,
    model: []const u8,
    effort: []const u8,
) ?Selection {
    for (catalog) |entry| {
        if (!std.mem.eql(u8, entry.id, model)) continue;
        for (entry.reasoning_efforts.items, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate.label(), effort)) {
                return .{ .entry = entry, .effort = candidate, .effort_index = index };
            }
        }
        return null;
    }
    return null;
}

fn validateRequest(request: Request) !void {
    if (request.model.len == 0 or request.model.len > 1024) return error.InvalidModel;
    for (request.model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidModel;
    }
    const effort = types.ReasoningEffort.parse(request.effort) orelse return error.InvalidEffort;
    if (effort.isDefault() or !std.mem.eql(u8, effort.label(), request.effort)) {
        return error.InvalidEffort;
    }
    if (request.prompt.len == 0 or request.prompt.len > max_prompt_bytes or
        !std.unicode.utf8ValidateSlice(request.prompt))
    {
        return error.InvalidPrompt;
    }
    try schema_validator.validateObjectSchema(request.schema, .{});
}

const AdmissionContext = struct {
    entry: *ledger.LockedEntry,
    request_digest: [Sha256.digest_length]u8,
    cancel_flag: *std.atomic.Value(bool),
    cancellation_frame: []const u8,
    attempt_evidence: *stream_provider.AttemptEvidence,
    admitted: bool = false,
    cancelled_terminal_saved: bool = false,

    fn admit(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.admitted or self.cancelled_terminal_saved) return error.DuplicateProviderAdmission;
        if (self.cancel_flag.load(.seq_cst)) {
            try self.entry.save(.{
                .request_digest = self.request_digest,
                .phase = .terminal,
                .terminal_frame = @constCast(self.cancellation_frame),
            });
            self.cancelled_terminal_saved = true;
            return error.Cancelled;
        }
        try self.entry.save(.{
            .request_digest = self.request_digest,
            .phase = .provider_admitted,
        });
        self.attempt_evidence.provider_admitted = true;
        self.admitted = true;
    }
};

const EventCapture = struct {
    saw_tool_event: bool = false,

    fn emit(raw: *anyopaque, event: stream_provider.Event) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .tool_started, .tool_input_delta => self.saw_tool_event = true,
            .content_delta, .reasoning_delta => {},
        }
    }
};

fn terminalizeCancelled(
    alloc: Allocator,
    entry: *ledger.LockedEntry,
    digest: [Sha256.digest_length]u8,
    code: []const u8,
    provenance: Provenance,
) ![]u8 {
    return terminalize(
        alloc,
        entry,
        digest,
        .cancelled,
        null,
        .{ .stage = "cancellation", .code = code },
        provenance,
    );
}

fn terminalize(
    alloc: Allocator,
    entry: *ledger.LockedEntry,
    digest: [Sha256.digest_length]u8,
    status: Status,
    output_json: ?[]const u8,
    failure: ?Failure,
    provenance: Provenance,
) ![]u8 {
    const frame = buildTerminalFrame(
        alloc,
        digest,
        status,
        output_json,
        failure,
        provenance,
    ) catch |err| switch (err) {
        error.TerminalFrameTooLarge => fallback: {
            var bounded_provenance = provenance;
            bounded_provenance.provider_response_id = null;
            const fallback_status: Status = if (output_json != null) .schema_failed else .provider_failed;
            const fallback_failure = Failure{
                .stage = if (output_json != null) "response_schema" else "persistence",
                .code = "terminal_frame_too_large",
            };
            break :fallback try buildTerminalFrame(
                alloc,
                digest,
                fallback_status,
                null,
                fallback_failure,
                bounded_provenance,
            );
        },
        else => return err,
    };
    errdefer alloc.free(frame);
    try entry.save(.{
        .request_digest = digest,
        .phase = .terminal,
        .terminal_frame = frame,
    });
    return frame;
}

fn buildTerminalFrame(
    alloc: Allocator,
    request_digest: [Sha256.digest_length]u8,
    status: Status,
    output_json: ?[]const u8,
    failure: ?Failure,
    provenance: Provenance,
) ![]u8 {
    if ((status == .succeeded) != (output_json != null)) return error.InvalidTerminalOutcome;
    if ((status == .succeeded) == (failure != null)) return error.InvalidTerminalOutcome;
    const request_hex = std.fmt.bytesToHex(request_digest, .lower);
    const receipt_id = receiptId(request_digest, status, output_json, failure, provenance.provider_response_id);
    const receipt_hex = std.fmt.bytesToHex(receipt_id, .lower);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema_id\":");
    try std.json.Stringify.value(schema_id, .{}, &out.writer);
    try out.writer.print(",\"version\":{d},\"operation\":\"infer\",\"status\":", .{wire_version});
    try std.json.Stringify.value(@tagName(status), .{}, &out.writer);
    try out.writer.writeAll(",\"request_digest\":");
    try std.json.Stringify.value(&request_hex, .{}, &out.writer);
    try out.writer.writeAll(",\"receipt\":{\"id\":");
    try std.json.Stringify.value(&receipt_hex, .{}, &out.writer);
    try out.writer.writeAll(",\"acknowledged\":false},\"output\":");
    if (output_json) |value| try out.writer.writeAll(value) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"failure\":");
    if (failure) |value| {
        try out.writer.writeAll("{\"stage\":");
        try std.json.Stringify.value(value.stage, .{}, &out.writer);
        try out.writer.writeAll(",\"code\":");
        try std.json.Stringify.value(value.code, .{}, &out.writer);
        try out.writer.print(",\"retryable\":{s}}}", .{if (value.retryable) "true" else "false"});
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"provenance\":{\"credential_source\":");
    if (provenance.credential_source) |source| {
        try std.json.Stringify.value(@tagName(source), .{}, &out.writer);
    } else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"credential_identity_sha256\":");
    if (provenance.credential_identity) |identity| {
        const identity_hex = std.fmt.bytesToHex(identity.bytes, .lower);
        try std.json.Stringify.value(&identity_hex, .{}, &out.writer);
    } else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"catalog_provider\":\"codex\",\"catalog_protocol\":\"chatgpt-codex-models\",\"catalog_client_version\":");
    try std.json.Stringify.value(provenance.catalog_client_version, .{}, &out.writer);
    try out.writer.writeAll(",\"model\":");
    try std.json.Stringify.value(provenance.model, .{}, &out.writer);
    try out.writer.writeAll(",\"effort\":");
    try std.json.Stringify.value(provenance.effort, .{}, &out.writer);
    try out.writer.writeAll(",\"effort_index\":");
    if (provenance.effort_index) |index| try out.writer.print("{d}", .{index}) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"catalog_selection_digest\":");
    if (provenance.catalog_selection_digest) |digest| {
        const selection_hex = std.fmt.bytesToHex(digest, .lower);
        try std.json.Stringify.value(&selection_hex, .{}, &out.writer);
    } else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"provider\":\"codex\",\"provider_protocol\":");
    try std.json.Stringify.value(provenance.provider_protocol, .{}, &out.writer);
    try out.writer.writeAll(",\"provider_response_id\":");
    if (provenance.provider_response_id) |id| {
        try std.json.Stringify.value(id, .{}, &out.writer);
    } else try out.writer.writeAll("null");
    try out.writer.writeAll("}}");
    if (out.written().len > ledger.max_terminal_frame_bytes) return error.TerminalFrameTooLarge;
    return out.toOwnedSlice();
}

fn buildAckFrame(alloc: Allocator, receipt_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema_id\":");
    try std.json.Stringify.value(schema_id, .{}, &out.writer);
    try out.writer.print(",\"version\":{d},\"operation\":\"ack\",\"receipt_id\":", .{wire_version});
    try std.json.Stringify.value(receipt_id, .{}, &out.writer);
    try out.writer.writeAll(",\"acknowledged\":true}");
    return out.toOwnedSlice();
}

fn receiptIdFromFrame(alloc: Allocator, frame: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, frame, .{}) catch
        return error.StructuredInferenceLedgerCorrupt;
    defer parsed.deinit();
    if (parsed.value != .object) return error.StructuredInferenceLedgerCorrupt;
    const receipt = parsed.value.object.get("receipt") orelse return error.StructuredInferenceLedgerCorrupt;
    if (receipt != .object) return error.StructuredInferenceLedgerCorrupt;
    const id = receipt.object.get("id") orelse return error.StructuredInferenceLedgerCorrupt;
    if (id != .string or id.string.len != Sha256.digest_length * 2) {
        return error.StructuredInferenceLedgerCorrupt;
    }
    return alloc.dupe(u8, id.string);
}

fn requestDigest(
    model: []const u8,
    effort: []const u8,
    prompt: []const u8,
    canonical_schema: []const u8,
) [Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hash.update("fx-structured-subscription-request-v1\x00");
    hashField(&hash, model);
    hashField(&hash, effort);
    hashField(&hash, prompt);
    hashField(&hash, canonical_schema);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn catalogSelectionDigest(
    entry: model_catalog.ModelCatalogEntry,
    selected_index: usize,
) [Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hash.update("fx-structured-subscription-catalog-selection-v1\x00");
    hashField(&hash, entry.id);
    for (entry.reasoning_efforts.items) |effort| hashField(&hash, effort.label());
    var index_bytes: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &index_bytes, selected_index, .big);
    hash.update(&index_bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn receiptId(
    request_digest: [Sha256.digest_length]u8,
    status: Status,
    output_json: ?[]const u8,
    failure: ?Failure,
    provider_response_id: ?[]const u8,
) [Sha256.digest_length]u8 {
    var hash = Sha256.init(.{});
    hash.update("fx-structured-subscription-receipt-v1\x00");
    hash.update(&request_digest);
    hashField(&hash, @tagName(status));
    hashField(&hash, output_json orelse "");
    hashField(&hash, if (failure) |value| value.stage else "");
    hashField(&hash, if (failure) |value| value.code else "");
    hashField(&hash, provider_response_id orelse "");
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashField(hash: *Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hash.update(&length);
    hash.update(bytes);
}

fn catalogFailureCode(category: model_catalog.FailureCategory) []const u8 {
    return switch (category) {
        .authentication => "catalog_authentication_failed",
        .rate_limited => "catalog_rate_limited",
        .gateway_unavailable => "catalog_unavailable",
        .cancellation => "catalog_cancelled",
        .transport => "catalog_transport_failed",
        .malformed_response => "catalog_malformed_response",
        .http_status => "catalog_http_status_failed",
        .resource_exhausted => "catalog_resource_exhausted",
        .runtime => "catalog_runtime_failed",
    };
}

fn providerErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout => "provider_timeout",
        error.Cancelled => "provider_cancelled",
        else => "provider_transport_failed",
    };
}

fn providerFailureCode(kind: stream_provider.FailureKind) []const u8 {
    return switch (kind) {
        .invalid_request => "provider_invalid_request",
        .unauthorized => "provider_unauthorized",
        .forbidden => "provider_forbidden",
        .request_too_large => "provider_request_too_large",
        .rate_limited => "provider_rate_limited",
        .server_error => "provider_server_error",
        .bad_gateway => "provider_bad_gateway",
        .unavailable => "provider_unavailable",
        .gateway_timeout => "provider_gateway_timeout",
        .provider_error => "provider_error",
    };
}

fn providerFailureRetryable(kind: stream_provider.FailureKind) bool {
    return switch (kind) {
        .rate_limited, .server_error, .bad_gateway, .unavailable, .gateway_timeout => true,
        else => false,
    };
}

const TestMode = enum {
    success,
    refusal,
    schema_failure,
    provider_failure,
    cancel_after_admission,
};

const TestRuntime = struct {
    sequence: std.ArrayList(u8) = .empty,
    credential_calls: usize = 0,
    catalog_calls: usize = 0,
    provider_calls: usize = 0,
    mode: TestMode = .success,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    request_shape_valid: bool = false,
    response_id: []const u8 = "resp_test",
    response_content: []const u8 = "{\"choice\":\"yes\"}",
    content_capture_overflowed: bool = false,

    fn deinit(self: *TestRuntime, alloc: Allocator) void {
        self.sequence.deinit(alloc);
    }

    fn resolveCredential(raw: ?*anyopaque, alloc: Allocator) !?credentials.Credential {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.credential_calls += 1;
        try self.sequence.append(alloc, 'R');
        return .{
            .token = try alloc.dupe(u8, "test-token"),
            .source = .chatgpt_subscription,
            .account_id = try alloc.dupe(u8, "acct_test"),
        };
    }

    fn fetchCatalog(
        raw: ?*anyopaque,
        alloc: Allocator,
        input: model_catalog.FetchInput,
    ) Allocator.Error!model_catalog.ProviderResult {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.catalog_calls += 1;
        self.sequence.append(alloc, 'C') catch return error.OutOfMemory;
        if (input.access.credentialSource() != .chatgpt_subscription) {
            return .{ .failure = .{ .category = .authentication } };
        }
        var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer efforts.deinit(alloc);
        try efforts.append(alloc, types.ReasoningEffort.literal("low"));
        try efforts.append(alloc, types.ReasoningEffort.literal("high"));
        var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
        errdefer model_catalog.freeModelCatalog(alloc, &catalog);
        try catalog.append(alloc, .{
            .id = try alloc.dupe(u8, "gpt-test"),
            .model_type = try alloc.dupe(u8, "language"),
            .has_reasoning = true,
            .reasoning_efforts = efforts,
        });
        return .{ .catalog = catalog };
    }

    fn stream(
        raw: ?*anyopaque,
        _: Allocator,
        request: stream_provider.ModelRequest,
    ) anyerror!stream_provider.Result {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.provider_calls += 1;
        try self.sequence.append(std.testing.allocator, 'P');
        self.request_shape_valid =
            std.mem.eql(u8, request.model, "gpt-test") and
            request.retry_count == 1 and
            request.session_id == null and
            request.messages.len == 1 and
            request.messages[0].role == .user and
            std.mem.eql(u8, request.messages[0].content orelse "", "Return a choice.") and
            request.tools.advertised_names.len == 0 and
            request.tools.advertised_functions.len == 0 and
            request.tools.additional_functions.len == 0 and
            request.tools.selected_dynamic.len == 0 and
            request.tool_choice == .none and
            request.response_format != null and
            request.response_format.?.schema == .object and
            request.provider_options.reasoning != null and
            std.mem.eql(u8, request.provider_options.reasoning.?.label(), "high");
        try request.admission.admit();
        if (self.mode == .cancel_after_admission) {
            self.cancel_flag.?.store(true, .seq_cst);
        }
        return switch (self.mode) {
            .success, .cancel_after_admission => .{ .completed = .{
                .completion = .{
                    .content = self.response_content,
                    .content_capture_overflowed = self.content_capture_overflowed,
                    .generation_id = self.response_id,
                    .finish_reason = .stop,
                },
            } },
            .refusal => .{ .completed = .{
                .completion = .{
                    .content = "policy refusal",
                    .generation_id = "resp_refused",
                    .finish_reason = .content_filter,
                },
            } },
            .schema_failure => .{ .completed = .{
                .completion = .{
                    .content = "{\"choice\":7}",
                    .generation_id = "resp_schema",
                    .finish_reason = .stop,
                },
            } },
            .provider_failure => .{ .failed = .{ .kind = .unavailable } },
        };
    }

    fn dependencies(self: *@This()) Dependencies {
        return .{
            .credential = .{ .context = self, .resolve_fn = resolveCredential },
            .catalog = .{ .context = self, .fetch_fn = fetchCatalog },
            .responses = .{ .context = self, .stream_fn = stream },
            .catalog_client_version = "test-catalog-v1",
            .provider_protocol = "test-responses-v1",
        };
    }
};

const test_schema_text =
    \\{"type":"object","properties":{"choice":{"type":"string"}},"required":["choice"],"additionalProperties":false}
;

fn testStateRoot(alloc: Allocator, tmp: std.testing.TmpDir, leaf: []const u8) ![]u8 {
    const parent = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(parent);
    return std.fs.path.join(alloc, &.{ parent, leaf });
}

fn terminalStatus(alloc: Allocator, frame: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get("status").?;
    return alloc.dupe(u8, value.string);
}

fn receiptFromTerminal(alloc: Allocator, frame: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    return alloc.dupe(u8, parsed.value.object.get("receipt").?.object.get("id").?.string);
}

test "structured subscription inference enforces catalog order and exact tool-free request" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_root = try testStateRoot(alloc, tmp, "success-state");
    defer alloc.free(state_root);
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, test_schema_text, .{});
    defer schema.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var runtime: TestRuntime = .{};
    defer runtime.deinit(alloc);

    const frame = try infer(alloc, state_root, .{
        .model = "gpt-test",
        .effort = "high",
        .prompt = "Return a choice.",
        .schema = schema.value,
        .caller_key = "success-key",
        .cancel_flag = &cancelled,
    }, runtime.dependencies());
    defer alloc.free(frame);
    try std.testing.expectEqualStrings("RCP", runtime.sequence.items);
    try std.testing.expect(runtime.request_shape_valid);
    try std.testing.expectEqual(@as(usize, 1), runtime.catalog_calls);
    try std.testing.expectEqual(@as(usize, 1), runtime.provider_calls);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("succeeded", parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("yes", parsed.value.object.get("output").?.object.get("choice").?.string);
    const provenance = parsed.value.object.get("provenance").?.object;
    try std.testing.expectEqual(@as(i64, 1), provenance.get("effort_index").?.integer);
    try std.testing.expectEqualStrings("resp_test", provenance.get("provider_response_id").?.string);
    try std.testing.expect(provenance.get("credential_identity_sha256").?.string.len == 64);
    try std.testing.expect(provenance.get("catalog_selection_digest").?.string.len == 64);
}

test "structured subscription inference replays terminals rejects conflicts and acknowledges idempotently" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_root = try testStateRoot(alloc, tmp, "replay-state");
    defer alloc.free(state_root);
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, test_schema_text, .{});
    defer schema.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var runtime: TestRuntime = .{};
    defer runtime.deinit(alloc);
    const request = Request{
        .model = "gpt-test",
        .effort = "high",
        .prompt = "Return a choice.",
        .schema = schema.value,
        .caller_key = "replay-key",
        .cancel_flag = &cancelled,
    };

    const first = try infer(alloc, state_root, request, runtime.dependencies());
    defer alloc.free(first);
    const replay = try infer(alloc, state_root, request, runtime.dependencies());
    defer alloc.free(replay);
    try std.testing.expectEqualStrings(first, replay);
    try std.testing.expectEqual(@as(usize, 1), runtime.provider_calls);

    var conflicting = request;
    conflicting.prompt = "Different prompt.";
    try std.testing.expectError(
        error.StructuredInferenceCallerKeyConflict,
        infer(alloc, state_root, conflicting, runtime.dependencies()),
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.provider_calls);

    const receipt = try receiptFromTerminal(alloc, first);
    defer alloc.free(receipt);
    const first_ack = try acknowledge(alloc, state_root, request.caller_key, receipt);
    defer alloc.free(first_ack);
    const second_ack = try acknowledge(alloc, state_root, request.caller_key, receipt);
    defer alloc.free(second_ack);
    try std.testing.expectEqualStrings(first_ack, second_ack);
}

test "structured subscription inference durably classifies refusal schema and provider failures" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, test_schema_text, .{});
    defer schema.deinit();

    const cases = [_]struct {
        leaf: []const u8,
        key: []const u8,
        mode: TestMode,
        expected: []const u8,
    }{
        .{ .leaf = "refusal", .key = "refusal-key", .mode = .refusal, .expected = "refused" },
        .{ .leaf = "schema", .key = "schema-key", .mode = .schema_failure, .expected = "schema_failed" },
        .{ .leaf = "provider", .key = "provider-key", .mode = .provider_failure, .expected = "provider_failed" },
    };
    for (cases) |case| {
        const state_root = try testStateRoot(alloc, tmp, case.leaf);
        defer alloc.free(state_root);
        var cancelled = std.atomic.Value(bool).init(false);
        var runtime: TestRuntime = .{ .mode = case.mode };
        defer runtime.deinit(alloc);
        const request = Request{
            .model = "gpt-test",
            .effort = "high",
            .prompt = "Return a choice.",
            .schema = schema.value,
            .caller_key = case.key,
            .cancel_flag = &cancelled,
        };
        const first = try infer(alloc, state_root, request, runtime.dependencies());
        defer alloc.free(first);
        const status = try terminalStatus(alloc, first);
        defer alloc.free(status);
        try std.testing.expectEqualStrings(case.expected, status);
        const replay = try infer(alloc, state_root, request, runtime.dependencies());
        defer alloc.free(replay);
        try std.testing.expectEqualStrings(first, replay);
        try std.testing.expectEqual(@as(usize, 1), runtime.provider_calls);
    }
}

test "structured subscription inference cancellation is durable before admission and provider terminal wins after admission" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, test_schema_text, .{});
    defer schema.deinit();

    const before_root = try testStateRoot(alloc, tmp, "cancel-before");
    defer alloc.free(before_root);
    var cancelled_before = std.atomic.Value(bool).init(true);
    var before_runtime: TestRuntime = .{};
    defer before_runtime.deinit(alloc);
    const before_request = Request{
        .model = "gpt-test",
        .effort = "high",
        .prompt = "Return a choice.",
        .schema = schema.value,
        .caller_key = "cancel-before-key",
        .cancel_flag = &cancelled_before,
    };
    const before = try infer(alloc, before_root, before_request, before_runtime.dependencies());
    defer alloc.free(before);
    const before_status = try terminalStatus(alloc, before);
    defer alloc.free(before_status);
    try std.testing.expectEqualStrings("cancelled", before_status);
    try std.testing.expectEqual(@as(usize, 0), before_runtime.credential_calls);
    cancelled_before.store(false, .seq_cst);
    const before_replay = try infer(alloc, before_root, before_request, before_runtime.dependencies());
    defer alloc.free(before_replay);
    try std.testing.expectEqualStrings(before, before_replay);

    const after_root = try testStateRoot(alloc, tmp, "cancel-after");
    defer alloc.free(after_root);
    var cancelled_after = std.atomic.Value(bool).init(false);
    var after_runtime: TestRuntime = .{
        .mode = .cancel_after_admission,
        .cancel_flag = &cancelled_after,
    };
    defer after_runtime.deinit(alloc);
    const after = try infer(alloc, after_root, .{
        .model = "gpt-test",
        .effort = "high",
        .prompt = "Return a choice.",
        .schema = schema.value,
        .caller_key = "cancel-after-key",
        .cancel_flag = &cancelled_after,
    }, after_runtime.dependencies());
    defer alloc.free(after);
    const after_status = try terminalStatus(alloc, after);
    defer alloc.free(after_status);
    try std.testing.expectEqualStrings("succeeded", after_status);
    try std.testing.expect(cancelled_after.load(.seq_cst));
}

test "structured subscription inference recovers admitted request without a second provider call" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_root = try testStateRoot(alloc, tmp, "recovery-state");
    defer alloc.free(state_root);
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, test_schema_text, .{});
    defer schema.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    const canonical = try schema_validator.canonicalStringify(alloc, schema.value);
    defer alloc.free(canonical);
    const digest = requestDigest("gpt-test", "high", "Return a choice.", canonical);
    var store = try ledger.Store.init(state_root);
    defer store.deinit();
    var entry = try store.lock(alloc, "recovery-key");
    try entry.save(.{ .request_digest = digest, .phase = .provider_admitted });
    entry.deinit();

    var runtime: TestRuntime = .{};
    defer runtime.deinit(alloc);
    const recovered = try infer(alloc, state_root, .{
        .model = "gpt-test",
        .effort = "high",
        .prompt = "Return a choice.",
        .schema = schema.value,
        .caller_key = "recovery-key",
        .cancel_flag = &cancelled,
    }, runtime.dependencies());
    defer alloc.free(recovered);
    const status = try terminalStatus(alloc, recovered);
    defer alloc.free(status);
    try std.testing.expectEqualStrings("provider_failed", status);
    try std.testing.expectEqual(@as(usize, 0), runtime.provider_calls);
}

test "structured subscription inference bounds provider identifiers and terminal persistence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, test_schema_text, .{});
    defer schema.deinit();
    var cancelled = std.atomic.Value(bool).init(false);

    const output_prefix = "{\"choice\":\"";
    const output_suffix = "\"}";
    const exact_output = try alloc.alloc(u8, max_provider_output_bytes);
    defer alloc.free(exact_output);
    @memcpy(exact_output[0..output_prefix.len], output_prefix);
    @memset(
        exact_output[output_prefix.len .. exact_output.len - output_suffix.len],
        'x',
    );
    @memcpy(exact_output[exact_output.len - output_suffix.len ..], output_suffix);

    const exact_output_root = try testStateRoot(alloc, tmp, "exact-output-state");
    defer alloc.free(exact_output_root);
    var exact_output_runtime: TestRuntime = .{ .response_content = exact_output };
    defer exact_output_runtime.deinit(alloc);
    const exact_output_frame = try infer(alloc, exact_output_root, .{
        .model = "gpt-test",
        .effort = "high",
        .prompt = "Return a choice.",
        .schema = schema.value,
        .caller_key = "exact-output-key",
        .cancel_flag = &cancelled,
    }, exact_output_runtime.dependencies());
    defer alloc.free(exact_output_frame);
    const exact_output_status = try terminalStatus(alloc, exact_output_frame);
    defer alloc.free(exact_output_status);
    try std.testing.expectEqualStrings("succeeded", exact_output_status);

    const overflow_root = try testStateRoot(alloc, tmp, "overflow-output-state");
    defer alloc.free(overflow_root);
    var overflow_runtime: TestRuntime = .{
        .response_content = exact_output,
        .content_capture_overflowed = true,
    };
    defer overflow_runtime.deinit(alloc);
    const overflow_frame = try infer(alloc, overflow_root, .{
        .model = "gpt-test",
        .effort = "high",
        .prompt = "Return a choice.",
        .schema = schema.value,
        .caller_key = "overflow-output-key",
        .cancel_flag = &cancelled,
    }, overflow_runtime.dependencies());
    defer alloc.free(overflow_frame);
    var parsed_overflow = try std.json.parseFromSlice(std.json.Value, alloc, overflow_frame, .{});
    defer parsed_overflow.deinit();
    try std.testing.expectEqualStrings(
        "schema_failed",
        parsed_overflow.value.object.get("status").?.string,
    );
    try std.testing.expectEqualStrings(
        "structured_output_size_invalid",
        parsed_overflow.value.object.get("failure").?.object.get("code").?.string,
    );

    const response_id = try alloc.alloc(u8, max_provider_response_id_bytes + 1);
    defer alloc.free(response_id);
    @memset(response_id, 'r');
    var runtime: TestRuntime = .{ .response_id = response_id };
    defer runtime.deinit(alloc);
    const response_id_root = try testStateRoot(alloc, tmp, "response-id-state");
    defer alloc.free(response_id_root);
    const bounded = try infer(alloc, response_id_root, .{
        .model = "gpt-test",
        .effort = "high",
        .prompt = "Return a choice.",
        .schema = schema.value,
        .caller_key = "response-id-key",
        .cancel_flag = &cancelled,
    }, runtime.dependencies());
    defer alloc.free(bounded);
    const bounded_status = try terminalStatus(alloc, bounded);
    defer alloc.free(bounded_status);
    try std.testing.expectEqualStrings("provider_failed", bounded_status);

    const terminal_root = try testStateRoot(alloc, tmp, "terminal-budget-state");
    defer alloc.free(terminal_root);
    var store = try ledger.Store.init(terminal_root);
    defer store.deinit();
    var entry = try store.lock(alloc, "terminal-budget-key");
    defer entry.deinit();
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("terminal-budget", &digest, .{});
    try entry.save(.{ .request_digest = digest, .phase = .started });
    const oversized_output = try alloc.alloc(u8, ledger.max_terminal_frame_bytes);
    defer alloc.free(oversized_output);
    @memset(oversized_output, 'a');
    @memcpy(oversized_output[0..6], "{\"x\":\"");
    @memcpy(oversized_output[oversized_output.len - 2 ..], "\"}");
    const fallback = try terminalize(
        alloc,
        &entry,
        digest,
        .succeeded,
        oversized_output,
        null,
        .{
            .model = "gpt-test",
            .effort = "high",
            .catalog_client_version = "test-catalog-v1",
            .provider_protocol = "test-responses-v1",
        },
    );
    defer alloc.free(fallback);
    var parsed_fallback = try std.json.parseFromSlice(std.json.Value, alloc, fallback, .{});
    defer parsed_fallback.deinit();
    try std.testing.expectEqualStrings("schema_failed", parsed_fallback.value.object.get("status").?.string);
    try std.testing.expectEqualStrings(
        "terminal_frame_too_large",
        parsed_fallback.value.object.get("failure").?.object.get("code").?.string,
    );
    var persisted = (try entry.load()).?;
    defer persisted.deinit(alloc);
    try std.testing.expectEqualStrings(fallback, persisted.terminal_frame.?);
}
