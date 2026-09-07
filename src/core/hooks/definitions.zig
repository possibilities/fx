const std = @import("std");
const types = @import("../shared/types.zig");

pub const HookKind = enum {
    turn_started,
    pre_tool_use,
    stop,
    post_turn_end,
    attention_required,
    attention_resolved,

    pub fn definition(self: HookKind) HookDefinition {
        return switch (self) {
            .turn_started => turn_started,
            .pre_tool_use => pre_tool_use,
            .stop => stop,
            .post_turn_end => post_turn_end,
            .attention_required => attention_required,
            .attention_resolved => attention_resolved,
        };
    }
};

pub const HookDefinition = struct {
    kind: HookKind,
    lifecycle_event: []const u8,
    agent_loop_point: []const u8,
    purpose: []const u8,
};

pub const turn_started = HookDefinition{
    .kind = .turn_started,
    .lifecycle_event = "TurnStarted",
    .agent_loop_point = "after a turn receives its stable identity and before agent execution",
    .purpose = "lets handlers observe every accepted top-level and subagent turn",
};

pub const pre_tool_use = HookDefinition{
    .kind = .pre_tool_use,
    .lifecycle_event = "PreToolUse",
    .agent_loop_point = "before local tool validation, permissions, and execution",
    .purpose = "lets handlers keep a call unchanged, rewrite its arguments, or block it",
};

pub const stop = HookDefinition{
    .kind = .stop,
    .lifecycle_event = "Stop",
    .agent_loop_point = "after a terminal assistant candidate before turn finalization",
    .purpose = "lets handlers allow completion or request one synthetic continuation",
};

pub const post_turn_end = HookDefinition{
    .kind = .post_turn_end,
    .lifecycle_event = "PostTurnEnd",
    .agent_loop_point = "after a terminal turn outcome is accepted",
    .purpose = "lets handlers observe terminal turns and run side effects without changing the turn outcome",
};

pub const attention_required = HookDefinition{
    .kind = .attention_required,
    .lifecycle_event = "AttentionRequired",
    .agent_loop_point = "after a user decision prompt becomes active",
    .purpose = "lets handlers observe when a foreground turn is waiting for user attention",
};

pub const attention_resolved = HookDefinition{
    .kind = .attention_resolved,
    .lifecycle_event = "AttentionResolved",
    .agent_loop_point = "after an active user decision is accepted and agent work can continue",
    .purpose = "lets handlers observe when a foreground turn no longer needs user attention",
};

pub const all_hooks = [_]HookDefinition{
    turn_started,
    pre_tool_use,
    stop,
    post_turn_end,
    attention_required,
    attention_resolved,
};

pub const ScopeKind = enum {
    interactive,
    ask,
    acp,
    subagent,
};

pub const Scope = struct {
    kind: ScopeKind,
    workspace_root: []const u8,
    session_id: ?[]const u8 = null,
    subagent_id: ?u64 = null,
    /// The main session that owned this subagent when the work was admitted,
    /// captured rather than read live. A `/new` or resume replaces the active
    /// main session while a child is still running, and reattributing that
    /// child's later records to the new session makes two records about one
    /// child disagree about its parent. Null on a main scope, and null on a
    /// subagent scope whose caller has no captured identity to offer.
    parent_session_id: ?[]const u8 = null,
};

pub const Invocation = struct {
    scope: Scope,
    turn_id: ?u64 = null,
};

pub const TurnStartedInput = struct {
    invocation: Invocation,
};

pub const TurnStartedHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: TurnStartedInput,
    ) HandlerError!void,
};

pub const Limits = struct {
    pub const handler_name_bytes = 128;
    pub const reason_bytes = 4 * 1024;
    pub const context_bytes = 64 * 1024;
    pub const arguments_json_bytes = 1024 * 1024;
};

pub const RegistrationError = error{
    EmptyHandlerName,
    HandlerNameTooLong,
    InvalidHandlerName,
    DuplicateHandlerName,
    RuntimeFrozen,
};

pub const ViewError = error{
    RuntimeNotFrozen,
};

pub const HandlerError = error{
    Failed,
    Cancelled,
};

pub const MutationDispatchError = error{
    OutOfMemory,
    HandlerFailed,
    Cancelled,
    InvalidHandlerOutput,
    HandlerOutputTooLarge,
};

pub const PreToolUseInput = struct {
    invocation: Invocation,
    step_index: usize,
    call_id: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
};

pub const PreToolUseAction = union(enum) {
    continue_,
    rewrite_arguments: []const u8,
    block: []const u8,
};

pub const PreToolUseOutcome = union(enum) {
    unchanged,
    rewritten: []u8,
    blocked: []u8,

    pub fn deinit(self: *PreToolUseOutcome, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .rewritten => |arguments_json| alloc.free(arguments_json),
            .blocked => |reason| alloc.free(reason),
            .unchanged => {},
        }
        self.* = .unchanged;
    }
};

pub const PreToolUseHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: PreToolUseInput,
    ) HandlerError!PreToolUseAction,
};

pub const StopInput = struct {
    invocation: Invocation,
    step_index: usize,
    assistant_text: []const u8,
    provider_disposition: types.ProviderCompletionDisposition,
    can_continue: bool,
};

pub const StopAction = union(enum) {
    allow,
    continue_once: []const u8,
};

pub const StopOutcome = union(enum) {
    allow,
    continue_once: []u8,

    pub fn deinit(self: *StopOutcome, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .continue_once => |context| alloc.free(context),
            .allow => {},
        }
        self.* = .allow;
    }
};

pub const StopHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: StopInput,
    ) HandlerError!StopAction,
};

pub const PostTurnEndInput = struct {
    invocation: Invocation,
    outcome: types.TurnPresentationOutcome,
    provider_disposition: ?types.ProviderCompletionDisposition = null,
};

pub const PostTurnEndHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: PostTurnEndInput,
    ) HandlerError!void,
};

pub const AttentionKind = enum {
    permission,
    question,
    route_recovery,
};

/// Internal identity for one attention request. First-party lifecycle
/// projections use it to reject a delayed edge after that exact request was
/// already resolved; it is not part of any external event schema.
pub const AttentionToken = [32]u8;

pub const AttentionRequiredInput = struct {
    invocation: Invocation,
    kind: AttentionKind,
    presented_interactively: bool = false,
    attention_token: ?AttentionToken = null,
};

pub const AttentionRequiredHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: AttentionRequiredInput,
    ) HandlerError!void,
};

pub const AttentionResolvedInput = struct {
    invocation: Invocation,
    kind: AttentionKind,
    presented_interactively: bool = false,
    attention_token: ?AttentionToken = null,
};

pub const AttentionResolvedHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: AttentionResolvedInput,
    ) HandlerError!void,
};

test "hook definitions enumerate current hook surfaces" {
    try std.testing.expectEqual(@as(usize, 6), all_hooks.len);
    try std.testing.expectEqual(HookKind.turn_started, all_hooks[0].kind);
    try std.testing.expectEqual(HookKind.pre_tool_use, all_hooks[1].kind);
    try std.testing.expectEqual(HookKind.stop, all_hooks[2].kind);
    try std.testing.expectEqual(HookKind.post_turn_end, all_hooks[3].kind);
    try std.testing.expectEqual(HookKind.attention_required, all_hooks[4].kind);
    try std.testing.expectEqual(HookKind.attention_resolved, all_hooks[5].kind);
    try std.testing.expectEqualStrings("TurnStarted", turn_started.lifecycle_event);
    try std.testing.expectEqualStrings("PreToolUse", pre_tool_use.lifecycle_event);
    try std.testing.expectEqualStrings("Stop", stop.lifecycle_event);
    try std.testing.expectEqualStrings("PostTurnEnd", post_turn_end.lifecycle_event);
    try std.testing.expectEqualStrings("AttentionRequired", attention_required.lifecycle_event);
    try std.testing.expectEqualStrings("AttentionResolved", attention_resolved.lifecycle_event);
    try std.testing.expectEqual(HookKind.turn_started, HookKind.turn_started.definition().kind);
    try std.testing.expectEqual(HookKind.pre_tool_use, HookKind.pre_tool_use.definition().kind);
    try std.testing.expectEqual(HookKind.stop, HookKind.stop.definition().kind);
    try std.testing.expectEqual(HookKind.post_turn_end, HookKind.post_turn_end.definition().kind);
    try std.testing.expectEqual(HookKind.attention_required, HookKind.attention_required.definition().kind);
    try std.testing.expectEqual(HookKind.attention_resolved, HookKind.attention_resolved.definition().kind);
    try std.testing.expectEqualStrings("TurnStarted", HookKind.turn_started.definition().lifecycle_event);
    try std.testing.expectEqualStrings("PreToolUse", HookKind.pre_tool_use.definition().lifecycle_event);
    try std.testing.expectEqualStrings("Stop", HookKind.stop.definition().lifecycle_event);
    try std.testing.expectEqualStrings("PostTurnEnd", HookKind.post_turn_end.definition().lifecycle_event);
    try std.testing.expectEqualStrings("AttentionRequired", HookKind.attention_required.definition().lifecycle_event);
    try std.testing.expectEqualStrings("AttentionResolved", HookKind.attention_resolved.definition().lifecycle_event);
    try std.testing.expect(turn_started.agent_loop_point.len > 0);
    try std.testing.expect(turn_started.purpose.len > 0);
    try std.testing.expect(pre_tool_use.agent_loop_point.len > 0);
    try std.testing.expect(pre_tool_use.purpose.len > 0);
    try std.testing.expect(stop.agent_loop_point.len > 0);
    try std.testing.expect(stop.purpose.len > 0);
    try std.testing.expect(post_turn_end.agent_loop_point.len > 0);
    try std.testing.expect(post_turn_end.purpose.len > 0);
    try std.testing.expect(attention_required.agent_loop_point.len > 0);
    try std.testing.expect(attention_required.purpose.len > 0);
    try std.testing.expect(attention_resolved.agent_loop_point.len > 0);
    try std.testing.expect(attention_resolved.purpose.len > 0);
}

test "Hooks v1.0 scope kinds remain limited to the current surfaces" {
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(ScopeKind).@"enum".fields.len);
}
