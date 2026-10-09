//! Voice-control surface for `fx acp`.
//!
//! A realtime voice client drives one ACP session and needs three things the
//! bare protocol does not give it: in-flight steering of the active turn,
//! an authoritative snapshot of queued work and children, and a lifecycle
//! feed at parity with the ADE event feed. This module owns all three plus
//! the question relay, and it reuses the native machinery rather than
//! duplicating it: admission and steering go through `WorkerRuntime`, the
//! semantic snapshot comes from the shared lifecycle reducer, and the queue
//! encoding is the work-control encoder's own.
//!
//! Every lifecycle record is one `session/update` notification whose
//! `sessionUpdate` kind is `_fx/lifecycle`. The envelope carries a monotonic
//! per-session `sequence`, the turn identity as a decimal string, the acting
//! agent's role and name, and that agent's semantic snapshot.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const host_target = @import("../core/hosts/target.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const server = @import("server.zig");
const hooks = @import("../core/hooks/hooks.zig");
const lifecycle_state = @import("../builtins/hooks/lifecycle_state.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const work_control = @import("../core/control/work_control.zig");
const child_state = @import("../core/subagent/child_state.zig");
const approval_registry = @import("../core/subagent/approval_registry.zig");
const subagent_tool_host = @import("../core/subagent/tool_host.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const permissions = @import("../core/permissions/permissions.zig");
const auth_runtime = @import("../core/auth/auth_runtime.zig");
const credentials = @import("../core/auth/credentials.zig");
const types = @import("../core/shared/types.zig");
const secret = @import("../core/auth/secret.zig");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;
const writeJsonStr = jsonrpc.writeJsonStr;

/// Advertised extension revision. The consumer reads
/// `agentCapabilities._fx.lifecycle` to know which envelope it is holding.
pub const lifecycle_revision: u32 = 1;

pub const update_kind = "_fx/lifecycle";

const max_steer_text_bytes: usize = work_control.max_external_text_bytes;
const max_tracked_children: usize = 64;
const max_child_id_bytes: usize = 64;
const max_child_name_bytes: usize = 64;
const max_pending_child_approvals: usize = 8;
const max_session_id_bytes: usize = 128;
const pump_interval_ms: u64 = 25;

pub const Event = enum {
    fx_started,
    turn_started,
    turn_ended,
    attention_raised,
    attention_cleared,
    child_changed,
    question_raised,
    stop,

    fn wire(self: Event) []const u8 {
        return @tagName(self);
    }
};

pub const Role = enum { main, subagent };

/// One acting agent for one record: which reducer snapshot describes it, how
/// it is named on the wire, and the turn it is acting in.
pub const Actor = struct {
    role: Role = .main,
    agent: lifecycle_state.Agent = .main,
    name: ?[]const u8 = null,
    turn_id: ?u64 = null,

    pub fn main_actor(turn_id: ?u64) Actor {
        return .{ .role = .main, .agent = .main, .name = null, .turn_id = turn_id };
    }

    pub fn child(session_id: []const u8, name: ?[]const u8, turn_id: ?u64) Actor {
        return .{
            .role = .subagent,
            .agent = .{ .subagent_session = session_id },
            .name = name,
            .turn_id = turn_id,
        };
    }
};

const TurnEndedDetail = struct {
    outcome: types.TurnPresentationOutcome,
    provider_disposition: ?types.ProviderCompletionDisposition = null,
};

const ChildDetail = struct {
    id: []const u8,
    name: ?[]const u8,
    kind: child_state.Kind,
    phase: child_state.Phase,
};

const QuestionDetail = struct {
    question_id: u64,
    entries: []const types.QuestionBatchEntry,
};

const Detail = union(enum) {
    none,
    turn_ended: TurnEndedDetail,
    child: ChildDetail,
    question: QuestionDetail,
};

const TrackedChild = struct {
    id_buf: [max_child_id_bytes]u8 = undefined,
    id_len: usize = 0,
    name_buf: [max_child_name_bytes]u8 = undefined,
    name_len: usize = 0,
    has_name: bool = false,
    kind: child_state.Kind = .one_off,
    phase: child_state.Phase = .idle,
    used: bool = false,

    fn id(self: *const TrackedChild) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    fn name(self: *const TrackedChild) ?[]const u8 {
        return if (self.has_name) self.name_buf[0..self.name_len] else null;
    }
};

/// One child approval already published to the client and awaiting an answer.
const ChildApproval = struct {
    outbound_id: u64 = 0,
    request_id_buf: [max_child_id_bytes]u8 = undefined,
    request_id_len: usize = 0,
    child_id_buf: [max_child_id_bytes]u8 = undefined,
    child_id_len: usize = 0,
    name_buf: [max_child_name_bytes]u8 = undefined,
    name_len: usize = 0,
    has_name: bool = false,
    used: bool = false,

    fn requestId(self: *const ChildApproval) []const u8 {
        return self.request_id_buf[0..self.request_id_len];
    }

    fn childId(self: *const ChildApproval) []const u8 {
        return self.child_id_buf[0..self.child_id_len];
    }

    fn name(self: *const ChildApproval) ?[]const u8 {
        return if (self.has_name) self.name_buf[0..self.name_len] else null;
    }
};

pub const Runtime = struct {
    alloc: Allocator = std.heap.c_allocator,
    mutex: std.Io.Mutex = .init,
    sequence: u64 = 0,
    session_id: []u8 = &.{},
    session_bound: bool = false,
    reducer: lifecycle_state.Reducer = .{},

    children: [max_tracked_children]TrackedChild = @splat(.{}),
    child_approvals: [max_pending_child_approvals]ChildApproval = @splat(.{}),

    pump_thread: if (host_target.is_wasm) void else ?std.Thread =
        if (host_target.is_wasm) {} else null,
    pump_stop: std.atomic.Value(bool) = .init(false),
    pump_generation: u64 = 0,

    pub fn init(self: *Runtime, alloc: Allocator) void {
        self.alloc = alloc;
        self.reducer.init(alloc);
    }

    pub fn deinit(self: *Runtime) void {
        stopPump(self);
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (self.session_id.len > 0) self.alloc.free(self.session_id);
        self.session_id = &.{};
        self.session_bound = false;
        self.mutex.unlock(io);
        self.reducer.deinit();
    }

    fn currentSessionId(self: *Runtime) ?[]const u8 {
        if (!self.session_bound) return null;
        return self.session_id;
    }

    /// Copies the bound session id for a caller off the dispatch thread. The
    /// stored slice is replaced whenever the active session changes, so a
    /// background thread must never hold it across a lock release.
    fn copySessionId(self: *Runtime, buffer: []u8) ?[]const u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const session_id = self.currentSessionId() orelse return null;
        if (session_id.len > buffer.len) return null;
        @memcpy(buffer[0..session_id.len], session_id);
        return buffer[0..session_id.len];
    }
};

// -------------------------------------------------------------------------
// Session binding
// -------------------------------------------------------------------------

/// Binds the lifecycle feed to one active session. The sequence restarts at
/// one per session, and `fx_started` opens it lazily with the session's first
/// record, so a session that never does anything adds no traffic to a client
/// that is not watching for it.
pub fn bindSession(state: *server.ServerState, session_id: []const u8) void {
    const voice = &state.voice;
    const io = io_mod.getIo();
    voice.mutex.lockUncancelable(io);
    if (voice.session_id.len > 0) voice.alloc.free(voice.session_id);
    voice.session_id = voice.alloc.dupe(u8, session_id) catch &.{};
    voice.session_bound = voice.session_id.len > 0;
    voice.sequence = 0;
    voice.mutex.unlock(io);
}

/// Rebinds the feed whenever the active session changes, whichever request
/// changed it. `stop` closes the session that is leaving and `fx_started`
/// opens the one that arrives, so a client never sees two sessions share a
/// sequence.
pub fn syncSession(state: *server.ServerState) void {
    const active_id: ?[]const u8 = if (state.active_session) |*session| session.session_id else null;
    const bound = state.voice.currentSessionId();
    if (active_id) |id| {
        if (bound) |current| {
            if (std.mem.eql(u8, current, id)) return;
            releaseSession(state);
        }
        bindSession(state, id);
        return;
    }
    if (bound != null) releaseSession(state);
}

/// Publishes the terminal `stop` for the bound session and unbinds it. Called
/// when the session closes and once more when the ACP connection ends.
pub fn releaseSession(state: *server.ServerState) void {
    const voice = &state.voice;
    if (!voice.session_bound) return;
    // A feed that never opened needs no terminal record.
    if (voice.sequence > 0) emit(state, .stop, Actor.main_actor(null), .none);
    const io = io_mod.getIo();
    voice.mutex.lockUncancelable(io);
    if (voice.session_id.len > 0) voice.alloc.free(voice.session_id);
    voice.session_id = &.{};
    voice.session_bound = false;
    voice.mutex.unlock(io);
}

// -------------------------------------------------------------------------
// Lifecycle hooks
// -------------------------------------------------------------------------

/// Registers this projection on the ACP server's own hook runtime. Turn and
/// attention edges then arrive for the main agent and every in-process child
/// without a second instrumentation path.
pub fn registerLifecycleHooks(state: *server.ServerState) !void {
    try state.lifecycle_runtime.registerTurnStarted(.{
        .name = "fx.acp.voice.turn_started",
        .ctx = state,
        .run = turnStartedHandler,
    });
    try state.lifecycle_runtime.registerStop(.{
        .name = "fx.acp.voice.stop",
        .ctx = state,
        .run = stopHandler,
    });
    try state.lifecycle_runtime.registerPostTurnEnd(.{
        .name = "fx.acp.voice.turn_end",
        .ctx = state,
        .run = postTurnEndHandler,
    });
    try state.lifecycle_runtime.registerAttentionRequired(.{
        .name = "fx.acp.voice.attention_required",
        .ctx = state,
        .run = attentionRequiredHandler,
    });
    try state.lifecycle_runtime.registerAttentionResolved(.{
        .name = "fx.acp.voice.attention_resolved",
        .ctx = state,
        .run = attentionResolvedHandler,
    });
}

/// Maps a hook scope onto the reducer's agent identity. The reducer's own
/// `Agent.fromScope` deliberately answers null for ACP because the ADE feed
/// is interactive-only; this projection is the ACP-side answer to the same
/// question and keeps the reducer's per-agent independence.
fn actorForScope(scope: hooks.Scope, turn_id: ?u64) ?Actor {
    return switch (scope.kind) {
        .interactive, .acp => Actor.main_actor(turn_id),
        .subagent => if (scope.session_id) |session_id|
            Actor.child(session_id, null, turn_id)
        else if (scope.subagent_id) |subagent_id|
            .{
                .role = .subagent,
                .agent = .{ .subagent_id = subagent_id },
                .name = null,
                .turn_id = turn_id,
            }
        else
            .{
                .role = .subagent,
                .agent = .anonymous_subagent,
                .name = null,
                .turn_id = turn_id,
            },
        .ask => null,
    };
}

fn turnStartedHandler(ctx: *anyopaque, input: hooks.TurnStartedInput) hooks.HandlerError!void {
    const state: *server.ServerState = @ptrCast(@alignCast(ctx));
    const actor = actorForScope(input.invocation.scope, input.invocation.turn_id) orelse return;
    _ = state.voice.reducer.transition(actor.agent, .turn_started, null);
    emit(state, .turn_started, actor, .none);
}

fn stopHandler(ctx: *anyopaque, input: hooks.StopInput) hooks.HandlerError!hooks.StopAction {
    const state: *server.ServerState = @ptrCast(@alignCast(ctx));
    const actor = actorForScope(input.invocation.scope, input.invocation.turn_id) orelse return .allow;
    _ = state.voice.reducer.transition(actor.agent, .stop, null);
    return .allow;
}

fn postTurnEndHandler(ctx: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
    const state: *server.ServerState = @ptrCast(@alignCast(ctx));
    const actor = actorForScope(input.invocation.scope, input.invocation.turn_id) orelse return;
    _ = state.voice.reducer.transition(actor.agent, .post_turn_end, null);
    emit(state, .turn_ended, actor, .{ .turn_ended = .{
        .outcome = input.outcome,
        .provider_disposition = input.provider_disposition,
    } });
}

fn attentionRequiredHandler(ctx: *anyopaque, input: hooks.AttentionRequiredInput) hooks.HandlerError!void {
    const state: *server.ServerState = @ptrCast(@alignCast(ctx));
    const actor = actorForScope(input.invocation.scope, input.invocation.turn_id) orelse return;
    publishAttentionRequired(state, actor, input.kind, input.attention_token);
}

fn attentionResolvedHandler(ctx: *anyopaque, input: hooks.AttentionResolvedInput) hooks.HandlerError!void {
    const state: *server.ServerState = @ptrCast(@alignCast(ctx));
    const actor = actorForScope(input.invocation.scope, input.invocation.turn_id) orelse return;
    publishAttentionResolved(state, actor, input.kind, input.attention_token);
}

/// Raises attention for one agent, publishing only a real transition so a
/// repeated edge for the same identity stays one record.
pub fn publishAttentionRequired(
    state: *server.ServerState,
    actor: Actor,
    kind: hooks.AttentionKind,
    token: ?hooks.AttentionToken,
) void {
    const update = state.voice.reducer.transitionWithToken(
        actor.agent,
        .attention_required,
        kind,
        token,
    );
    if (!update.changed()) return;
    emit(state, .attention_raised, actor, .none);
}

pub fn publishAttentionResolved(
    state: *server.ServerState,
    actor: Actor,
    kind: hooks.AttentionKind,
    token: ?hooks.AttentionToken,
) void {
    const update = state.voice.reducer.transitionWithToken(
        actor.agent,
        .attention_resolved,
        kind,
        token,
    );
    if (!update.changed()) return;
    emit(state, .attention_cleared, actor, .none);
}

// -------------------------------------------------------------------------
// Record publication
// -------------------------------------------------------------------------

fn emit(state: *server.ServerState, event: Event, actor: Actor, detail: Detail) void {
    const voice = &state.voice;
    const snapshot = voice.reducer.snapshot(actor.agent);

    const io = io_mod.getIo();
    voice.mutex.lockUncancelable(io);
    defer voice.mutex.unlock(io);
    const session_id = voice.currentSessionId() orelse return;
    if (voice.sequence == 0 and event != .fx_started) {
        voice.sequence = 1;
        writeAndPublish(state, session_id, .fx_started, 1, Actor.main_actor(null), .{
            .agent_state = .idle,
            .attention_kind = null,
        }, .none);
    }
    voice.sequence += 1;
    const sequence = voice.sequence;

    writeAndPublish(state, session_id, event, sequence, actor, snapshot, detail);
}

fn writeAndPublish(
    state: *server.ServerState,
    session_id: []const u8,
    event: Event,
    sequence: u64,
    actor: Actor,
    snapshot: lifecycle_state.Snapshot,
    detail: Detail,
) void {
    const alloc = state.voice.alloc;
    var update: std.Io.Writer.Allocating = .init(alloc);
    defer update.deinit();
    writeRecord(&update.writer, event, sequence, actor, snapshot, detail) catch |err| {
        debug_trace.logf("acp_voice", "record serialization failed event={s} err={s}", .{
            event.wire(),
            @errorName(err),
        });
        return;
    };

    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    acp_types.writeSessionUpdate(&params.writer, session_id, update.written()) catch |err| {
        debug_trace.logf("acp_voice", "record envelope failed event={s} err={s}", .{
            event.wire(),
            @errorName(err),
        });
        return;
    };
    state.writer.writeNotification(alloc, "session/update", params.written()) catch |err| {
        debug_trace.logf("acp_voice", "record publication failed event={s} err={s}", .{
            event.wire(),
            @errorName(err),
        });
    };
}

fn writeRecord(
    writer: *std.Io.Writer,
    event: Event,
    sequence: u64,
    actor: Actor,
    snapshot: lifecycle_state.Snapshot,
    detail: Detail,
) !void {
    try writer.writeAll("{\"sessionUpdate\":");
    try writeJsonStr(update_kind, writer);
    try writer.writeAll(",\"event\":");
    try writeJsonStr(event.wire(), writer);
    try writer.print(",\"sequence\":{d},\"turn_id\":", .{sequence});
    if (actor.turn_id) |turn_id| {
        try writeTurnId(writer, turn_id);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"agent_role\":");
    try writeJsonStr(@tagName(actor.role), writer);
    try writer.writeAll(",\"agent_name\":");
    if (actor.name) |name| try writeJsonStr(name, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"agent_state\":");
    try writeJsonStr(@tagName(snapshot.agent_state), writer);
    try writer.writeAll(",\"attention_kind\":");
    if (snapshot.attention_kind) |kind| {
        try writeJsonStr(attentionKindWire(kind), writer);
    } else {
        try writer.writeAll("null");
    }
    switch (detail) {
        .none => {},
        .turn_ended => |ended| {
            try writer.writeAll(",\"outcome\":");
            try writeJsonStr(@tagName(ended.outcome), writer);
            try writer.writeAll(",\"provider_disposition\":");
            if (ended.provider_disposition) |disposition| {
                try writeJsonStr(@tagName(disposition), writer);
            } else {
                try writer.writeAll("null");
            }
        },
        .child => |child| {
            try writer.writeAll(",\"child\":{\"id\":");
            try writeJsonStr(child.id, writer);
            try writer.writeAll(",\"name\":");
            if (child.name) |name| try writeJsonStr(name, writer) else try writeJsonStr(child.id, writer);
            try writer.writeAll(",\"kind\":");
            try writeJsonStr(@tagName(child.kind), writer);
            try writer.writeAll(",\"phase\":");
            try writeJsonStr(@tagName(child.phase), writer);
            try writer.writeByte('}');
        },
        .question => |question| {
            try writer.writeAll(",\"question_id\":");
            try writeTurnId(writer, question.question_id);
            try writer.writeAll(",\"text\":");
            if (question.entries.len > 0) {
                try writeJsonStr(question.entries[0].question, writer);
            } else {
                try writeJsonStr("", writer);
            }
            try writer.writeAll(",\"options\":[");
            if (question.entries.len > 0) {
                for (question.entries[0].options, 0..) |option, index| {
                    if (index > 0) try writer.writeByte(',');
                    try writeJsonStr(option.label, writer);
                }
            }
            try writer.writeAll("],\"questions\":[");
            for (question.entries, 0..) |entry, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeAll("{\"question\":");
                try writeJsonStr(entry.question, writer);
                try writer.writeAll(",\"options\":[");
                for (entry.options, 0..) |option, option_index| {
                    if (option_index > 0) try writer.writeByte(',');
                    try writeJsonStr(option.label, writer);
                }
                try writer.writeAll("]}");
            }
            try writer.writeByte(']');
        },
    }
    try writer.writeByte('}');
}

/// The ADE feed's spelling for the recovery attention kind is `route_recovery`;
/// keep the ACP projection identical so one consumer vocabulary covers both.
fn attentionKindWire(kind: hooks.AttentionKind) []const u8 {
    return @tagName(kind);
}

fn writeTurnId(writer: *std.Io.Writer, value: u64) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try writeJsonStr(text, writer);
}

// -------------------------------------------------------------------------
// `_fx/session/steer`
// -------------------------------------------------------------------------

pub const SteerOutcome = struct {
    started_turn: bool = false,
};

pub fn handleSteer(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    defer parsed.deinit();
    if (!try server.requireParsedActiveSessionTarget(state, alloc, msg.id, parsed.value)) return;

    const text_value = parsed.value.object.get("text") orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing text",
        });
    if (text_value != .string or text_value.string.len == 0) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Empty steering text",
        });
    }
    if (text_value.string.len > max_steer_text_bytes) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Steering text exceeds its bound",
        });
    }

    const session = if (state.active_session) |*active| active else unreachable;
    const draft = buildSteeringDraft(session, text_value.string) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to admit steering text",
        });
    var draft_owned = true;
    errdefer if (draft_owned) worker_runtime.freeQueuedPrompt(std.heap.c_allocator, draft);

    const admission = state.worker.admitPromptObserved(
        std.heap.c_allocator,
        draft,
        true,
        null,
    ) catch |err| {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = admissionErrorMessage(err),
        });
    };
    draft_owned = false;

    var snapshot = state.worker.snapshotWork(std.heap.c_allocator, .{
        .max_entries = work_control.max_snapshot_entries,
        .max_text_bytes = work_control.max_snapshot_text_bytes,
    }) catch |err| {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = admissionErrorMessage(err),
        });
    };
    defer snapshot.deinit(std.heap.c_allocator);

    // Steering names the turn it joined; queueing names the turn it created.
    const reported_turn_id = switch (admission.disposition) {
        .steering => snapshot.active_turn_id orelse admission.turn_id,
        .queued => admission.turn_id,
    };

    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.writeAll("{\"turnId\":");
    try writeTurnId(&response.writer, reported_turn_id);
    try response.writer.writeAll(",\"disposition\":");
    try writeJsonStr(@tagName(admission.disposition), &response.writer);
    try response.writer.writeAll(",\"snapshot\":");
    try writeSnapshotWithChildren(state, &response.writer, snapshot);
    try response.writer.writeByte('}');
    try state.writer.writeResponse(alloc, msg.id, response.written());

    if (admission.disposition == .queued) server.startQueuedWork(state, alloc);
}

fn admissionErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.WorkerStopped => "the agent worker has stopped",
        error.TurnFinalizationDeliveryFailed => "the active turn could not be finalized",
        error.WorkSnapshotEntryLimitExceeded,
        error.WorkSnapshotTextLimitExceeded,
        => "the authoritative work snapshot exceeds its bound",
        else => "Fx could not admit the steering text",
    };
}

/// The queued draft carries the text and the routing identity only. A turn
/// that actually starts from it is rebuilt from the live session, so nothing
/// stale in the draft can reach the model.
fn buildSteeringDraft(
    session: *server.ActiveSessionState,
    text: []const u8,
) !worker_runtime.QueuedPrompt {
    const alloc = std.heap.c_allocator;
    const prompt = try alloc.dupe(u8, text);
    errdefer alloc.free(prompt);
    const model = try alloc.dupe(u8, session.model);
    errdefer alloc.free(model);
    const api_key = try alloc.dupe(u8, session.api_key);
    errdefer secret.zeroAndFree(alloc, api_key);
    const account_id = if (session.account_id) |value| try alloc.dupe(u8, value) else null;
    return .{
        .prompt = prompt,
        .images = &.{},
        .model = model,
        .provider = session.provider,
        .api_key = api_key,
        .credential_source = session.credential_source,
        .account_id = account_id,
        .permission_mode = session.permission_mode,
        .history = &.{},
        .grants = &.{},
    };
}

// -------------------------------------------------------------------------
// `_fx/session/snapshot`
// -------------------------------------------------------------------------

pub fn handleSnapshot(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    if (!try server.requireActiveSessionTarget(state, alloc, msg)) return;
    var snapshot = state.worker.snapshotWork(std.heap.c_allocator, .{
        .max_entries = work_control.max_snapshot_entries,
        .max_text_bytes = work_control.max_snapshot_text_bytes,
    }) catch |err| {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = admissionErrorMessage(err),
        });
    };
    defer snapshot.deinit(std.heap.c_allocator);

    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try writeSnapshotWithChildren(state, &response.writer, snapshot);
    try state.writer.writeResponse(alloc, msg.id, response.written());
}

/// The work-control snapshot fields verbatim, plus the parent's children.
/// The voice frontend needs both in one answer: queued work is what it can
/// still edit, and a child awaiting approval is what is blocking the person.
fn writeSnapshotWithChildren(
    state: *server.ServerState,
    writer: *std.Io.Writer,
    snapshot: worker_runtime.WorkSnapshot,
) !void {
    try writer.writeByte('{');
    try work_control.writeSnapshotFields(writer, snapshot);
    try writer.writeAll(",\"children\":[");
    if (comptime !host_target.is_wasm) {
        if (state.subagent_host) |host| {
            var registry = host.managed.state_store.load(std.heap.c_allocator) catch {
                try writer.writeAll("]}");
                return;
            };
            defer registry.deinit(std.heap.c_allocator);
            for (registry.children, 0..) |child, index| {
                if (index > 0) try writer.writeByte(',');
                try writeChildEntry(writer, child);
            }
        }
    }
    try writer.writeAll("]}");
}

fn writeChildEntry(writer: *std.Io.Writer, child: child_state.Child) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonStr(child.id, writer);
    try writer.writeAll(",\"name\":");
    try writeJsonStr(child.agentName() orelse child.id, writer);
    try writer.writeAll(",\"kind\":");
    try writeJsonStr(@tagName(child.kind), writer);
    try writer.writeAll(",\"phase\":");
    try writeJsonStr(@tagName(child.phase), writer);
    try writer.writeByte('}');
}

// -------------------------------------------------------------------------
// `_fx/status`
// -------------------------------------------------------------------------

pub fn handleStatus(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try writeIdentity(state, &response.writer);
    try state.writer.writeResponse(alloc, msg.id, response.written());
}

/// The identity `fx status --json` reports, plus the resolved model and
/// effort, so the adapter can verify what it is talking to without shelling
/// out. `model_source` and `connected_providers` are unconditional here: a
/// voice client checks them on every connection, not only off-gateway.
pub fn writeIdentity(state: *server.ServerState, writer: *std.Io.Writer) !void {
    const auth = authStatusSnapshot(state);
    try writer.writeAll("{\"build_revision\":");
    try writeJsonStr(build_options.git_commit, writer);
    try writer.writeAll(",\"version\":");
    try writeJsonStr(build_options.app_version, writer);
    try writer.writeAll(",\"auth\":");
    try writeJsonStr(auth.activeSourceLabel(), writer);
    try writer.writeAll(",\"model_source\":");
    try writeJsonStr(provider_catalog.label(state.provider), writer);
    try writer.writeAll(",\"connected_providers\":[");
    var wrote_provider = false;
    if (output_contracts.gatewayProviderConnected(auth)) {
        try writeJsonStr("vercel-ai-gateway", writer);
        wrote_provider = true;
    }
    if (output_contracts.chatGptProviderConnected(auth)) {
        if (wrote_provider) try writer.writeByte(',');
        try writeJsonStr("codex", writer);
        wrote_provider = true;
    }
    if (output_contracts.grokProviderConnected(auth)) {
        if (wrote_provider) try writer.writeByte(',');
        try writeJsonStr("grok", writer);
    }
    try writer.writeAll("],\"permission_mode\":");
    try writeJsonStr(permissions.permissionModeLabel(state.permission_mode), writer);
    try writer.writeAll(",\"model\":");
    try writeJsonStr(state.selected_model, writer);
    try writer.writeAll(",\"effort\":");
    try writeJsonStr(state.effort.label(), writer);
    try writer.writeAll(",\"workspace\":");
    try writeJsonStr(state.workspace_root, writer);
    try writer.writeByte('}');
}

/// Reports what this process actually resolved rather than re-reading the
/// credential store: an ACP identity answer must not perform store I/O on
/// every call, and the resolved source is the authority for this connection.
fn authStatusSnapshot(state: *server.ServerState) auth_runtime.StatusSnapshot {
    const source = state.credential_source;
    return .{
        .active_source = source,
        .team = state.gateway_team,
        .gateway_connected = source != null and
            source != .chatgpt_subscription and source != .grok_subscription,
        .chatgpt_connected = source == .chatgpt_subscription,
        .grok_connected = source == .grok_subscription,
    };
}

// -------------------------------------------------------------------------
// Question relay
// -------------------------------------------------------------------------

/// Serves one `ask_user_question` batch to the ACP client. The agent thread
/// blocks on the same correlated outbound slot a permission uses, so a
/// cancellation releases the question exactly the way it releases a
/// permission.
pub fn requestQuestionBatch(
    raw_ctx: ?*anyopaque,
    response_alloc: Allocator,
    entries: []const types.QuestionBatchEntry,
) anyerror!?[][]u8 {
    const state: *server.ServerState = @ptrCast(@alignCast(raw_ctx orelse return null));
    if (entries.len == 0) return null;
    const question_id = (server.beginOutboundRequest(state, .question) catch return null) orelse return null;

    const actor = Actor.main_actor(state.worker.activeTurnId());
    publishAttentionRequired(state, actor, .question, null);
    emit(state, .question_raised, actor, .{ .question = .{
        .question_id = question_id,
        .entries = entries,
    } });

    var response = server.awaitOutboundResponse(state, question_id, .question) orelse {
        publishAttentionResolved(state, actor, .question, null);
        return null;
    };
    defer response.deinit(state.alloc);
    publishAttentionResolved(state, actor, .question, null);
    if (response.cancelled or response.error_json != null) return null;
    const raw = response.result_json orelse return null;
    return parseQuestionAnswers(response_alloc, raw, entries.len);
}

fn parseQuestionAnswers(
    alloc: Allocator,
    raw: []const u8,
    expected: usize,
) !?[][]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const answers = try alloc.alloc([]u8, expected);
    var filled: usize = 0;
    errdefer {
        for (answers[0..filled]) |value| alloc.free(value);
        alloc.free(answers);
    }
    if (parsed.value.object.get("answers")) |value| {
        if (value != .array or value.array.items.len != expected) {
            alloc.free(answers);
            return null;
        }
        while (filled < expected) : (filled += 1) {
            const entry = value.array.items[filled];
            if (entry != .string) return null;
            answers[filled] = try alloc.dupe(u8, entry.string);
        }
        return answers;
    }
    if (expected != 1) {
        alloc.free(answers);
        return null;
    }
    const single = parsed.value.object.get("answer") orelse {
        alloc.free(answers);
        return null;
    };
    if (single != .string) {
        alloc.free(answers);
        return null;
    }
    answers[0] = try alloc.dupe(u8, single.string);
    filled = 1;
    return answers;
}

pub fn handleQuestion(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    defer parsed.deinit();
    if (!try server.requireParsedActiveSessionTarget(state, alloc, msg.id, parsed.value)) return;

    const id_value = parsed.value.object.get("questionId") orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing questionId",
        });
    const question_id = parseDecimalId(id_value) orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid questionId",
        });

    var answer_json: std.Io.Writer.Allocating = .init(alloc);
    defer answer_json.deinit();
    if (parsed.value.object.get("answers")) |value| {
        if (value != .array) return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid answers",
        });
        try answer_json.writer.writeAll("{\"answers\":");
        try std.json.Stringify.value(value, .{}, &answer_json.writer);
        try answer_json.writer.writeByte('}');
    } else if (parsed.value.object.get("answer")) |value| {
        if (value != .string) return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid answer",
        });
        try answer_json.writer.writeAll("{\"answer\":");
        try std.json.Stringify.value(value, .{}, &answer_json.writer);
        try answer_json.writer.writeByte('}');
    } else {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing answer",
        });
    }

    if (!server.resolveOutboundRequest(state, question_id, .question, answer_json.written())) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Unknown questionId",
        });
    }
    try state.writer.writeResponse(alloc, msg.id, "null");
}

fn parseDecimalId(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| if (number > 0) @intCast(number) else null,
        .string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

// -------------------------------------------------------------------------
// Child observation pump
// -------------------------------------------------------------------------

/// Starts the child observation pump for one ACP turn. It polls the parent's
/// own child registry and approval registry, publishes every child phase
/// transition, and routes a child approval to the client through the parent
/// session, which is the only surface upstream lets a child approval reach.
pub fn startChildPump(state: *server.ServerState) void {
    if (comptime host_target.is_wasm) return;
    if (state.subagent_host == null) return;
    const voice = &state.voice;
    if (voice.pump_thread != null) return;
    voice.pump_stop.store(false, .seq_cst);
    voice.pump_thread = std.Thread.spawn(.{}, pumpMain, .{state}) catch |err| {
        debug_trace.logf("acp_voice", "child pump unavailable err={s}", .{@errorName(err)});
        return;
    };
}

pub fn stopChildPump(state: *server.ServerState) void {
    stopPump(&state.voice);
}

fn stopPump(self: *Runtime) void {
    if (comptime host_target.is_wasm) return;
    const thread = self.pump_thread orelse return;
    self.pump_stop.store(true, .seq_cst);
    thread.join();
    self.pump_thread = null;
    for (&self.child_approvals) |*approval| approval.* = .{};
}

fn pumpMain(state: *server.ServerState) void {
    while (!state.voice.pump_stop.load(.seq_cst)) {
        pollChildren(state);
        pollChildApprovals(state);
        // Sleep in slices so ending a turn is not held up by a poll interval.
        var slept: u64 = 0;
        while (slept < pump_interval_ms and !state.voice.pump_stop.load(.seq_cst)) : (slept += 1) {
            io_mod.sleep(std.time.ns_per_ms);
        }
    }
    // A turn that ends with an approval still outstanding leaves it for the
    // next turn's pump rather than answering on the person's behalf.
    pollChildApprovals(state);
}

/// Reconciles the tracked children against the parent's own registry. A child
/// the registry no longer lists is dropped here rather than cleared on a
/// session change, so this table is touched by the pump thread alone.
fn pollChildren(state: *server.ServerState) void {
    const host = state.subagent_host orelse return;
    var registry = host.managed.state_store.load(std.heap.c_allocator) catch return;
    defer registry.deinit(std.heap.c_allocator);

    const voice = &state.voice;
    var seen: [max_tracked_children]bool = @splat(false);
    for (registry.children) |child| {
        if (child.id.len > max_child_id_bytes) continue;
        var slot_index: ?usize = null;
        for (&voice.children, 0..) |*tracked, index| {
            if (!tracked.used) continue;
            if (!std.mem.eql(u8, tracked.id(), child.id)) continue;
            slot_index = index;
            break;
        }
        if (slot_index) |index| {
            seen[index] = true;
            const tracked = &voice.children[index];
            if (tracked.phase == child.phase) continue;
            tracked.phase = child.phase;
            publishChildChanged(state, child);
            continue;
        }
        for (&voice.children, 0..) |*tracked, index| {
            if (tracked.used) continue;
            tracked.* = .{ .used = true, .kind = child.kind, .phase = child.phase };
            @memcpy(tracked.id_buf[0..child.id.len], child.id);
            tracked.id_len = child.id.len;
            if (child.agentName()) |name| {
                if (name.len <= max_child_name_bytes) {
                    @memcpy(tracked.name_buf[0..name.len], name);
                    tracked.name_len = name.len;
                    tracked.has_name = true;
                }
            }
            seen[index] = true;
            publishChildChanged(state, child);
            break;
        }
    }
    for (&voice.children, 0..) |*tracked, index| {
        if (!tracked.used or seen[index]) continue;
        tracked.* = .{};
    }
}

fn publishChildChanged(state: *server.ServerState, child: child_state.Child) void {
    const actor = Actor.child(child.id, child.agentName() orelse child.id, null);
    emit(state, .child_changed, actor, .{ .child = .{
        .id = child.id,
        .name = child.agentName(),
        .kind = child.kind,
        .phase = child.phase,
    } });
}

fn pollChildApprovals(state: *server.ServerState) void {
    const host = state.subagent_host orelse return;
    resolveAnsweredChildApprovals(state, host);

    var pending = host.pendingApprovalRequest(std.heap.c_allocator) catch return;
    const request = if (pending) |*value| value else return;
    defer request.deinit(std.heap.c_allocator);
    if (request.request_id.len > max_child_id_bytes or
        request.child_id.len > max_child_id_bytes) return;
    if (childApprovalTracked(state, request.child_id)) return;

    const slot = reserveChildApproval(state) orelse return;
    const outbound_id = (server.beginOutboundRequest(state, .permission) catch null) orelse {
        slot.* = .{};
        return;
    };
    slot.outbound_id = outbound_id;
    @memcpy(slot.request_id_buf[0..request.request_id.len], request.request_id);
    slot.request_id_len = request.request_id.len;
    @memcpy(slot.child_id_buf[0..request.child_id.len], request.child_id);
    slot.child_id_len = request.child_id.len;
    // A one-off child has no agent name, so its session id is what names it.
    // The parent must be able to say which child is asking either way.
    const display_name = childDisplayName(state, request.child_id) orelse request.child_id;
    if (display_name.len <= max_child_name_bytes) {
        @memcpy(slot.name_buf[0..display_name.len], display_name);
        slot.name_len = display_name.len;
        slot.has_name = true;
    }

    const token = approval_registry.attentionToken(request.child_id, request.request_id);
    const child_actor = Actor.child(request.child_id, slot.name(), null);
    publishAttentionRequired(state, child_actor, .permission, token);
    // The person is talking to the parent, so the parent is what reports
    // blocked while one of its children waits.
    publishAttentionRequired(
        state,
        .{ .role = .main, .agent = .main, .name = slot.name(), .turn_id = state.worker.activeTurnId() },
        .permission,
        token,
    );

    sendChildPermissionRequest(state, outbound_id, request.*, slot.name()) catch |err| {
        debug_trace.logf("acp_voice", "child permission publication failed err={s}", .{@errorName(err)});
    };
}

fn childApprovalTracked(state: *server.ServerState, child_id: []const u8) bool {
    for (&state.voice.child_approvals) |*approval| {
        if (!approval.used) continue;
        if (std.mem.eql(u8, approval.childId(), child_id)) return true;
    }
    return false;
}

fn reserveChildApproval(state: *server.ServerState) ?*ChildApproval {
    for (&state.voice.child_approvals) |*approval| {
        if (approval.used) continue;
        approval.* = .{ .used = true };
        return approval;
    }
    return null;
}

fn childDisplayName(state: *server.ServerState, child_id: []const u8) ?[]const u8 {
    for (&state.voice.children) |*tracked| {
        if (!tracked.used) continue;
        if (!std.mem.eql(u8, tracked.id(), child_id)) continue;
        return tracked.name();
    }
    return null;
}

fn resolveAnsweredChildApprovals(
    state: *server.ServerState,
    host: *subagent_tool_host.Runtime,
) void {
    for (&state.voice.child_approvals) |*approval| {
        if (!approval.used) continue;
        var response = server.takeOutboundResponse(state, approval.outbound_id, .permission) orelse continue;
        defer response.deinit(state.alloc);
        const decision = server.permissionDecisionFromResponse(state, &response);
        const token = approval_registry.attentionToken(approval.childId(), approval.requestId());
        _ = host.resolveApproval(.{
            .request_id = approval.requestId(),
            .child_id = approval.childId(),
            .decision = decision,
            .timestamp_ms = io_mod.milliTimestamp(),
        }) catch |err| {
            debug_trace.logf("acp_voice", "child approval resolution failed err={s}", .{@errorName(err)});
        };
        const child_actor = Actor.child(approval.childId(), approval.name(), null);
        publishAttentionResolved(state, child_actor, .permission, token);
        publishAttentionResolved(
            state,
            .{ .role = .main, .agent = .main, .name = approval.name(), .turn_id = state.worker.activeTurnId() },
            .permission,
            token,
        );
        approval.* = .{};
    }
}

fn sendChildPermissionRequest(
    state: *server.ServerState,
    outbound_id: u64,
    request: approval_registry.PendingRequest,
    agent_name: ?[]const u8,
) !void {
    const alloc = state.alloc;
    var session_buffer: [max_session_id_bytes]u8 = undefined;
    const session_id = state.voice.copySessionId(&session_buffer) orelse return;
    const view = request.request.view();
    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    try params.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &params.writer);
    try params.writer.writeAll(",\"toolCall\":{\"toolCallId\":");
    try writeJsonStr(request.request_id, &params.writer);
    try params.writer.writeAll(",\"name\":\"subagent\",\"title\":");
    try writeJsonStr(view.label, &params.writer);
    try params.writer.writeAll(",\"kind\":\"other\",\"status\":\"pending\",\"rawInput\":{}},");
    try params.writer.writeAll("\"_fx\":{\"agent_role\":\"subagent\",\"agent_name\":");
    try writeJsonStr(agent_name orelse request.child_id, &params.writer);
    try params.writer.writeAll(",\"child_id\":");
    try writeJsonStr(request.child_id, &params.writer);
    try params.writer.writeAll("},\"options\":[");
    try params.writer.writeAll("{\"optionId\":\"allow_once\",\"name\":\"Allow once\",\"kind\":\"allow_once\"},");
    try params.writer.writeAll("{\"optionId\":\"allow_always\",\"name\":\"Allow for this session\",\"kind\":\"allow_always\"},");
    try params.writer.writeAll("{\"optionId\":\"reject_once\",\"name\":\"Reject\",\"kind\":\"reject_once\"}]}");
    try state.writer.writeRequest(
        alloc,
        .{ .integer = @intCast(outbound_id) },
        "session/request_permission",
        params.written(),
    );
}

test "ACP voice lifecycle records carry the envelope every consumer keys on" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeRecord(
        &out.writer,
        .turn_ended,
        7,
        Actor.main_actor(41),
        .{ .agent_state = .idle, .attention_kind = null },
        .{ .turn_ended = .{
            .outcome = .interrupted,
            .provider_disposition = .interrupted,
        } },
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(update_kind, root.get("sessionUpdate").?.string);
    try std.testing.expectEqualStrings("turn_ended", root.get("event").?.string);
    try std.testing.expectEqual(@as(i64, 7), root.get("sequence").?.integer);
    try std.testing.expectEqualStrings("41", root.get("turn_id").?.string);
    try std.testing.expectEqualStrings("main", root.get("agent_role").?.string);
    try std.testing.expectEqual(std.json.Value.null, root.get("agent_name").?);
    try std.testing.expectEqualStrings("idle", root.get("agent_state").?.string);
    try std.testing.expectEqual(std.json.Value.null, root.get("attention_kind").?);
    try std.testing.expectEqualStrings("interrupted", root.get("outcome").?.string);
    try std.testing.expectEqualStrings("interrupted", root.get("provider_disposition").?.string);
}

test "ACP voice blocked subagent record names the child and its attention" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeRecord(
        &out.writer,
        .child_changed,
        3,
        Actor.child("01J00000000000000000000001", "reviewer", null),
        .{ .agent_state = .blocked, .attention_kind = .permission },
        .{ .child = .{
            .id = "01J00000000000000000000001",
            .name = "reviewer",
            .kind = .{ .persistent = undefined },
            .phase = .awaiting_approval,
        } },
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("subagent", root.get("agent_role").?.string);
    try std.testing.expectEqualStrings("reviewer", root.get("agent_name").?.string);
    try std.testing.expectEqualStrings("blocked", root.get("agent_state").?.string);
    try std.testing.expectEqualStrings("permission", root.get("attention_kind").?.string);
    const child = root.get("child").?.object;
    try std.testing.expectEqualStrings("persistent", child.get("kind").?.string);
    try std.testing.expectEqualStrings("awaiting_approval", child.get("phase").?.string);
    try std.testing.expectEqualStrings("reviewer", child.get("name").?.string);
}

test "ACP voice route recovery keeps the ADE feed's attention spelling" {
    try std.testing.expectEqualStrings("route_recovery", attentionKindWire(.route_recovery));
    try std.testing.expectEqualStrings("permission", attentionKindWire(.permission));
    try std.testing.expectEqualStrings("question", attentionKindWire(.question));
}

test "ACP voice single question answer decodes only for a single-question batch" {
    const alloc = std.testing.allocator;
    const single = (try parseQuestionAnswers(alloc, "{\"answer\":\"yes\"}", 1)).?;
    defer {
        for (single) |value| alloc.free(value);
        alloc.free(single);
    }
    try std.testing.expectEqualStrings("yes", single[0]);
    try std.testing.expect(try parseQuestionAnswers(alloc, "{\"answer\":\"yes\"}", 2) == null);
    const batch = (try parseQuestionAnswers(alloc, "{\"answers\":[\"a\",\"b\"]}", 2)).?;
    defer {
        for (batch) |value| alloc.free(value);
        alloc.free(batch);
    }
    try std.testing.expectEqualStrings("a", batch[0]);
    try std.testing.expectEqualStrings("b", batch[1]);
}
