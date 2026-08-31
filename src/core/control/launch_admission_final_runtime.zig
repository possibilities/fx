const std = @import("std");
const worker_runtime = @import("../agent/worker_runtime.zig");
const io_mod = @import("../shared/io.zig");
const protocol = @import("launch_admission_final.zig");
const ledger_mod = @import("launch_admission_final_ledger.zig");

const Allocator = std.mem.Allocator;

// These fields are an opaque parent-to-child correlation tuple. They are not
// user configuration and do not replace native launch controls such as name,
// exact resume, selected state root, model, or effort.
pub const state_root_env = "FX_INTERNAL_LAUNCH_STATE_ROOT";
pub const admission_key_env = "FX_INTERNAL_LAUNCH_ADMISSION_KEY";
pub const launch_digest_env = "FX_INTERNAL_LAUNCH_DIGEST";
pub const launch_id_env = "FX_INTERNAL_LAUNCH_ID";
pub const conversation_id_env = "FX_INTERNAL_LAUNCH_CONVERSATION_ID";

const environment_keys = [_][]const u8{
    state_root_env,
    admission_key_env,
    launch_digest_env,
    launch_id_env,
    conversation_id_env,
};

pub const ChildContext = struct {
    alloc: Allocator,
    ledger: ledger_mod.Ledger,
    admission_key: []u8,
    launch_digest: []u8,
    launch_id: []u8,
    initial_work_digest: []u8,
    launch_conversation_id: []u8,
    fresh_launch: bool = false,
    invocation_validated: bool = false,
    reserved_conversation_consumed: bool = false,

    pub fn open(
        alloc: Allocator,
        state_root: []const u8,
        admission_key: []const u8,
        launch_digest: []const u8,
        launch_id: []const u8,
        initial_conversation_id: []const u8,
    ) !ChildContext {
        var ledger = try ledger_mod.Ledger.open(alloc, state_root, .{});
        errdefer ledger.deinit();
        var loaded = (try ledger.load(admission_key)) orelse return error.LaunchNotFound;
        defer loaded.deinit();
        if (!std.mem.eql(u8, loaded.record.launch_digest, launch_digest) or
            !std.mem.eql(u8, loaded.record.launch_id, launch_id) or
            (!std.mem.eql(u8, loaded.record.initial_conversation_id, initial_conversation_id) and
                !std.mem.eql(u8, loaded.record.active_conversation_id, initial_conversation_id)))
        {
            return error.CorrelationMismatch;
        }

        const owned_key = try alloc.dupe(u8, admission_key);
        errdefer alloc.free(owned_key);
        const owned_digest = try alloc.dupe(u8, launch_digest);
        errdefer alloc.free(owned_digest);
        const owned_launch_id = try alloc.dupe(u8, launch_id);
        errdefer alloc.free(owned_launch_id);
        const owned_work_digest = try alloc.dupe(u8, loaded.record.initial_work_digest);
        errdefer alloc.free(owned_work_digest);
        const owned_conversation_id = try alloc.dupe(u8, initial_conversation_id);
        errdefer alloc.free(owned_conversation_id);

        return .{
            .alloc = alloc,
            .ledger = ledger,
            .admission_key = owned_key,
            .launch_digest = owned_digest,
            .launch_id = owned_launch_id,
            .initial_work_digest = owned_work_digest,
            .launch_conversation_id = owned_conversation_id,
        };
    }

    /// Loads the all-or-none opaque child tuple. Absence preserves ordinary Fx
    /// behavior exactly; a partial tuple fails closed before Work-control starts.
    pub fn fromEnvironment(alloc: Allocator) !?ChildContext {
        var values: [environment_keys.len]?[]const u8 = undefined;
        var present: usize = 0;
        for (environment_keys, 0..) |key, index| {
            values[index] = io_mod.getenv(key);
            if (values[index] != null) present += 1;
        }
        if (present == 0) return null;
        if (present != environment_keys.len) return error.IncompleteLaunchAdmissionContext;
        return try open(
            alloc,
            values[0].?,
            values[1].?,
            values[2].?,
            values[3].?,
            values[4].?,
        );
    }

    pub fn deinit(self: *ChildContext) void {
        self.ledger.deinit();
        self.alloc.free(self.admission_key);
        self.alloc.free(self.launch_digest);
        self.alloc.free(self.launch_id);
        self.alloc.free(self.initial_work_digest);
        self.alloc.free(self.launch_conversation_id);
        self.* = undefined;
    }

    pub fn workerHook(self: *ChildContext) worker_runtime.DurableInitialAdmissionHook {
        std.debug.assert(self.invocation_validated);
        return .{
            .context = self,
            .matches_initial_fn = matchesInitialWork,
            .decide_fn = decideForWorker,
            .transition_fn = transitionForWorker,
        };
    }

    /// Binds the opaque ledger correlation to the one native interactive
    /// launch mode selected by the existing CLI. A fresh invocation may only
    /// consume the original reservation. Exact launch, recovery, and upgrade
    /// continuation must name the ledger's current active Conversation.
    pub fn validateInteractiveResume(
        self: *ChildContext,
        resume_requested: bool,
        requested_exact_id: ?[]const u8,
    ) !void {
        if (resume_requested != (requested_exact_id != null)) {
            return error.LaunchResumeMismatch;
        }
        var loaded = (try self.ledger.load(self.admission_key)) orelse
            return error.LaunchNotFound;
        defer loaded.deinit();
        if (!resume_requested) {
            if (loaded.record.resume_target != .fresh or
                !std.mem.eql(
                    u8,
                    loaded.record.initial_conversation_id,
                    self.launch_conversation_id,
                ) or
                !std.mem.eql(
                    u8,
                    loaded.record.active_conversation_id,
                    self.launch_conversation_id,
                ))
            {
                return error.LaunchResumeMismatch;
            }
            self.fresh_launch = true;
        } else {
            const requested = requested_exact_id.?;
            try protocol.validateConversationId(requested);
            if (!std.mem.eql(
                u8,
                requested,
                loaded.record.active_conversation_id,
            )) return error.LaunchResumeMismatch;
            if (!std.mem.eql(u8, requested, self.launch_conversation_id)) {
                const replacement = try self.alloc.dupe(u8, requested);
                self.alloc.free(self.launch_conversation_id);
                self.launch_conversation_id = replacement;
            }
            self.fresh_launch = false;
        }
        self.invocation_validated = true;
    }

    /// Returns an owned reserved identity exactly once for a fresh launch.
    /// Exact resume never enters the fresh-session identity path.
    pub fn takeReservedFreshConversationId(self: *ChildContext) !?[]u8 {
        if (!self.invocation_validated) return error.LaunchInvocationNotValidated;
        if (!self.fresh_launch or self.reserved_conversation_consumed) return null;
        const owned = try self.alloc.dupe(u8, self.launch_conversation_id);
        self.reserved_conversation_consumed = true;
        return owned;
    }

    pub fn expectedExactConversationId(self: *const ChildContext) ?[]const u8 {
        if (!self.invocation_validated or self.fresh_launch) return null;
        return self.launch_conversation_id;
    }

    pub fn publishActiveConversation(self: *ChildContext, conversation_id: []const u8) !void {
        var loaded = try self.ledger.updateActiveConversation(
            self.admission_key,
            self.launch_digest,
            self.launch_id,
            conversation_id,
        );
        loaded.deinit();
    }

    pub fn cancel(
        self: *ChildContext,
        request: protocol.AdmissionCancelRequest,
    ) !protocol.AdmissionDecision {
        var mutation = try self.ledger.cancel(request);
        defer mutation.deinit();
        return try cloneDecision(self.alloc, mutation.loaded.record.decision.?);
    }

    fn decideForWorker(
        raw: *anyopaque,
        prompt: []const u8,
        proposed: worker_runtime.DurableInitialAdmissionIdentity,
    ) !worker_runtime.DurableInitialAdmissionDecision {
        const self: *ChildContext = @ptrCast(@alignCast(raw));
        if (!matchesInitialWork(raw, prompt)) {
            return error.InitialWorkDigestMismatch;
        }
        const disposition: protocol.Disposition = switch (proposed.result.disposition) {
            .queued => .queued,
            .steering => .steering,
        };
        var mutation = self.ledger.admit(
            self.admission_key,
            self.launch_digest,
            self.launch_id,
            proposed.result.turn_id,
            disposition,
            proposed.steer_target_turn_id,
        ) catch |err| switch (err) {
            error.AdmissionCancelled => return .cancelled_before_start,
            else => return err,
        };
        defer mutation.deinit();
        const stored = mutation.loaded.record.decision.?.decision;
        return switch (stored) {
            .cancelled_before_start => .cancelled_before_start,
            .admitted => |admitted| .{ .admitted = .{
                .identity = .{
                    .result = .{
                        .turn_id = admitted.turn_id,
                        .disposition = switch (admitted.disposition) {
                            .queued => .queued,
                            .steering => .steering,
                        },
                    },
                    .steer_target_turn_id = mutation.delivery.?.steer_target_turn_id,
                },
                .phase = switch (mutation.delivery.?.phase) {
                    .decision_only => .decision_only,
                    .visible => .visible,
                    .consumed => .consumed,
                },
                .replayed = !mutation.newly_decided,
            } },
        };
    }

    fn transitionForWorker(
        raw: *anyopaque,
        identity: worker_runtime.DurableInitialAdmissionIdentity,
        phase: worker_runtime.DurableInitialAdmissionPhase,
    ) !void {
        const self: *ChildContext = @ptrCast(@alignCast(raw));
        const authority: ledger_mod.AdmissionAuthority = .{
            .turn_id = identity.result.turn_id,
            .disposition = switch (identity.result.disposition) {
                .queued => .queued,
                .steering => .steering,
            },
            .steer_target_turn_id = identity.steer_target_turn_id,
        };
        switch (phase) {
            .decision_only => return error.InvalidDurableAdmissionDecision,
            .visible => try self.ledger.markAdmissionVisible(
                self.admission_key,
                self.launch_digest,
                self.launch_id,
                authority,
            ),
            .consumed => try self.ledger.markAdmissionConsumed(
                self.admission_key,
                self.launch_digest,
                self.launch_id,
                authority,
            ),
        }
    }

    fn matchesInitialWork(raw: *anyopaque, prompt: []const u8) bool {
        const self: *ChildContext = @ptrCast(@alignCast(raw));
        const actual_work_digest = protocol.sha256Hex(prompt);
        return std.mem.eql(u8, &actual_work_digest, self.initial_work_digest);
    }
};

/// Adds the opaque tuple to a caller-owned child environment map.
pub fn applyChildEnvironment(
    map: *std.process.Environ.Map,
    record: ledger_mod.Record,
    conversation_id: []const u8,
) !void {
    try protocol.validateConversationId(conversation_id);
    if (!std.mem.eql(u8, conversation_id, record.initial_conversation_id) and
        !std.mem.eql(u8, conversation_id, record.active_conversation_id))
    {
        return error.CorrelationMismatch;
    }
    try map.put(state_root_env, record.state_root);
    try map.put(admission_key_env, record.admission_key);
    try map.put(launch_digest_env, record.launch_digest);
    try map.put(launch_id_env, record.launch_id);
    try map.put(conversation_id_env, conversation_id);
}

fn cloneDecision(alloc: Allocator, source: protocol.AdmissionDecision) !protocol.AdmissionDecision {
    const admission_key = try alloc.dupe(u8, source.admission_key);
    errdefer alloc.free(admission_key);
    const launch_digest = try alloc.dupe(u8, source.launch_digest);
    errdefer alloc.free(launch_digest);
    const launch_id = try alloc.dupe(u8, source.launch_id);
    errdefer alloc.free(launch_id);
    const receipt_digest = try alloc.dupe(u8, source.receipt_digest);
    errdefer alloc.free(receipt_digest);
    const receipt_id = try alloc.dupe(u8, source.receipt_id);
    errdefer alloc.free(receipt_id);
    const decision: protocol.AdmissionDecisionValue = switch (source.decision) {
        .admitted => |value| .{ .admitted = value },
        .cancelled_before_start => |value| .{ .cancelled_before_start = .{
            .cancellation_request_id = try alloc.dupe(u8, value.cancellation_request_id),
        } },
    };
    return .{
        .admission_key = admission_key,
        .decision = decision,
        .launch_digest = launch_digest,
        .launch_id = launch_id,
        .receipt_digest = receipt_digest,
        .receipt_id = receipt_id,
    };
}

pub fn freeClonedDecision(alloc: Allocator, decision: protocol.AdmissionDecision) void {
    alloc.free(@constCast(decision.admission_key));
    switch (decision.decision) {
        .admitted => {},
        .cancelled_before_start => |value| alloc.free(@constCast(value.cancellation_request_id)),
    }
    alloc.free(@constCast(decision.launch_digest));
    alloc.free(@constCast(decision.launch_id));
    alloc.free(@constCast(decision.receipt_digest));
    alloc.free(@constCast(decision.receipt_id));
}

fn testLaunchRequest(
    state_root: []const u8,
    prompt: []const u8,
    work_digest: *[64]u8,
    launch_digest: *[64]u8,
) !protocol.LaunchRequest {
    work_digest.* = protocol.sha256Hex(prompt);
    var request: protocol.LaunchRequest = .{
        .admission_key = "runtime-attempt",
        .conversation_name = "Runtime fixture",
        .directory = "/var/tmp/fx-runtime-fixture",
        .effort = "medium",
        .initial_work_digest = work_digest,
        .launch_digest = launch_digest,
        .launch_id = "runtime-launch",
        .model = "fixture/model",
        .remaining_launch_controls_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .request_id = "runtime-request",
        .resume_target = .fresh,
        .state_root = state_root,
    };
    launch_digest.* = try protocol.computeLaunchDigest(std.testing.allocator, request);
    request.launch_digest = launch_digest;
    return request;
}

fn testPrompt(alloc: Allocator, text: []const u8) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, text),
        .images = &.{},
        .model = try alloc.dupe(u8, "fixture/model"),
        .api_key = try alloc.dupe(u8, "fixture-key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(@import("../shared/types.zig").HistoryTurn, 0),
        .grants = try alloc.alloc(@import("../shared/types.zig").PermissionGrant, 0),
    };
}

test "launch child runtime consumes a fresh Conversation reservation once and publishes active identity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const prompt = "durably correlated initial work";
    var work_digest: [64]u8 = undefined;
    var launch_digest: [64]u8 = undefined;
    const request = try testLaunchRequest(root, prompt, &work_digest, &launch_digest);
    {
        var ledger = try ledger_mod.Ledger.open(alloc, root, .{});
        defer ledger.deinit();
        var accepted = try ledger.acceptLaunch(request, "reserved-conversation");
        accepted.deinit();
    }

    var context = try ChildContext.open(
        alloc,
        root,
        request.admission_key,
        request.launch_digest,
        request.launch_id,
        "reserved-conversation",
    );
    defer context.deinit();
    try context.validateInteractiveResume(false, null);
    const reserved = (try context.takeReservedFreshConversationId()).?;
    defer alloc.free(reserved);
    try std.testing.expectEqualStrings("reserved-conversation", reserved);
    try std.testing.expect((try context.takeReservedFreshConversationId()) == null);
    try context.publishActiveConversation("conversation-after-new");

    var loaded = (try context.ledger.load(request.admission_key)).?;
    defer loaded.deinit();
    try std.testing.expectEqualStrings(
        "conversation-after-new",
        loaded.record.active_conversation_id,
    );
}

test "launch child runtime requires fresh reservation or the exact active Conversation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const prompt = "durably correlated initial work";
    var work_digest: [64]u8 = undefined;
    var launch_digest: [64]u8 = undefined;
    var request = try testLaunchRequest(root, prompt, &work_digest, &launch_digest);
    request.resume_target = .{ .exact = "requested-conversation" };
    launch_digest = try protocol.computeLaunchDigest(alloc, request);
    request.launch_digest = &launch_digest;
    {
        var ledger = try ledger_mod.Ledger.open(alloc, root, .{});
        defer ledger.deinit();
        var accepted = try ledger.acceptLaunch(request, "requested-conversation");
        accepted.deinit();
        var active = try ledger.updateActiveConversation(
            request.admission_key,
            request.launch_digest,
            request.launch_id,
            "conversation-after-new",
        );
        active.deinit();
    }

    var context = try ChildContext.open(
        alloc,
        root,
        request.admission_key,
        request.launch_digest,
        request.launch_id,
        "requested-conversation",
    );
    defer context.deinit();
    try std.testing.expectError(
        error.LaunchResumeMismatch,
        context.validateInteractiveResume(false, null),
    );
    try std.testing.expectError(
        error.LaunchResumeMismatch,
        context.validateInteractiveResume(true, "requested-conversation"),
    );
    try context.validateInteractiveResume(true, "conversation-after-new");
    try std.testing.expectEqualStrings(
        "conversation-after-new",
        context.expectedExactConversationId().?,
    );
    try std.testing.expect((try context.takeReservedFreshConversationId()) == null);
}

test "launch child runtime durably decides the first Work-control prompt and replays its Turn" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const prompt_text = "durably correlated initial work";
    var work_digest: [64]u8 = undefined;
    var launch_digest: [64]u8 = undefined;
    const request = try testLaunchRequest(root, prompt_text, &work_digest, &launch_digest);
    {
        var ledger = try ledger_mod.Ledger.open(alloc, root, .{});
        defer ledger.deinit();
        var accepted = try ledger.acceptLaunch(request, "reserved-conversation");
        accepted.deinit();
    }
    var context = try ChildContext.open(
        alloc,
        root,
        request.admission_key,
        request.launch_digest,
        request.launch_id,
        "reserved-conversation",
    );
    defer context.deinit();
    try context.validateInteractiveResume(false, null);
    const first = first_process: {
        var worker = worker_runtime.WorkerRuntime{};
        defer worker.deinit(alloc);
        worker.setDurableInitialAdmissionHook(context.workerHook());
        break :first_process try worker.admitWorkControlPromptObserved(
            alloc,
            try testPrompt(alloc, prompt_text),
            false,
        );
    };

    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    worker.setDurableInitialAdmissionHook(context.workerHook());
    const mismatched = try testPrompt(alloc, "different initial work");
    defer worker_runtime.freeQueuedPrompt(alloc, mismatched);
    try std.testing.expectError(
        error.InitialWorkDigestMismatch,
        worker.admitWorkControlPromptObserved(alloc, mismatched, false),
    );
    const replay = try worker.admitWorkControlPromptObserved(
        alloc,
        try testPrompt(alloc, prompt_text),
        false,
    );
    try std.testing.expectEqual(first.turn_id, replay.turn_id);
    try std.testing.expectEqual(first.disposition, replay.disposition);
    try std.testing.expectEqual(@as(usize, 1), worker.queued_prompts.items.len);

    const lost_response_retry = try worker.admitWorkControlPromptObserved(
        alloc,
        try testPrompt(alloc, prompt_text),
        false,
    );
    try std.testing.expectEqual(first.turn_id, lost_response_retry.turn_id);
    try std.testing.expectEqual(first.disposition, lost_response_retry.disposition);
    try std.testing.expectEqual(@as(usize, 1), worker.queued_prompts.items.len);

    const consumed = (try worker.tryTakeNextPrompt(alloc)).?;
    worker_runtime.freeQueuedPrompt(alloc, consumed);

    const later = try worker.admitWorkControlPromptObserved(
        alloc,
        try testPrompt(alloc, "later ordinary work"),
        false,
    );
    try std.testing.expect(later.turn_id != replay.turn_id);
    try std.testing.expectEqual(@as(usize, 1), worker.queued_prompts.items.len);

    var after_process_loss = worker_runtime.WorkerRuntime{};
    defer after_process_loss.deinit(alloc);
    after_process_loss.setDurableInitialAdmissionHook(context.workerHook());
    const consumed_replay = try after_process_loss.admitWorkControlPromptObserved(
        alloc,
        try testPrompt(alloc, prompt_text),
        false,
    );
    try std.testing.expectEqual(first.turn_id, consumed_replay.turn_id);
    try std.testing.expectEqual(@as(usize, 0), after_process_loss.queued_prompts.items.len);

    var loaded = (try context.ledger.load(request.admission_key)).?;
    defer loaded.deinit();
    try std.testing.expectEqual(
        first.turn_id,
        loaded.record.decision.?.decision.admitted.turn_id,
    );
}
