//! Thread-safe semantic lifecycle state shared by first-party projections.
//!
//! The reducer owns no transport. Callers may hold the projection lock while
//! admitting an in-memory observation, but must release it before any socket
//! I/O or reply wait.

const std = @import("std");
const hooks = @import("../../core/hooks/hooks.zig");
const io_mod = @import("../../core/shared/io.zig");

pub const AgentState = enum {
    idle,
    working,
    blocked,
};

pub const Snapshot = struct {
    agent_state: AgentState = .idle,
    attention_kind: ?hooks.AttentionKind = null,
    attention_token: ?hooks.AttentionToken = null,
    closed_attention_tokens: [64]?hooks.AttentionToken = @splat(null),
    closed_attention_next: usize = 0,
};

pub const Event = enum {
    fx_started,
    prompt_queued,
    turn_started,
    pre_tool_use,
    stop,
    post_turn_end,
    attention_required,
    attention_resolved,
    attention_closed,
    fx_stopped,
};

pub const Agent = union(enum) {
    main,
    subagent_session: []const u8,
    subagent_id: u64,
    anonymous_subagent,

    pub fn fromScope(scope: hooks.Scope) ?Agent {
        return switch (scope.kind) {
            .interactive => .main,
            .subagent => if (scope.session_id) |session_id|
                .{ .subagent_session = session_id }
            else if (scope.subagent_id) |subagent_id|
                .{ .subagent_id = subagent_id }
            else
                .anonymous_subagent,
            .ask, .acp => null,
        };
    }
};

pub const Update = struct {
    previous: Snapshot,
    current: Snapshot,

    pub fn changed(self: Update) bool {
        return !std.meta.eql(self.previous, self.current);
    }
};

pub const Reducer = struct {
    alloc: ?std.mem.Allocator = null,
    mutex: std.Io.Mutex = .init,
    projection_mutex: std.Io.Mutex = .init,
    main: Snapshot = .{},
    subagent_sessions: std.StringHashMapUnmanaged(Snapshot) = .empty,
    subagent_ids: std.AutoHashMapUnmanaged(u64, Snapshot) = .empty,
    anonymous_subagent: Snapshot = .{},

    pub fn init(self: *Reducer, alloc: std.mem.Allocator) void {
        std.debug.assert(self.alloc == null);
        self.alloc = alloc;
    }

    pub fn deinit(self: *Reducer) void {
        const alloc = self.alloc orelse return;
        var keys = self.subagent_sessions.keyIterator();
        while (keys.next()) |key| alloc.free(key.*);
        self.subagent_sessions.deinit(alloc);
        self.subagent_ids.deinit(alloc);
        self.* = .{};
    }

    pub fn lockProjection(self: *Reducer) void {
        self.projection_mutex.lockUncancelable(io_mod.getIo());
    }

    pub fn unlockProjection(self: *Reducer) void {
        self.projection_mutex.unlock(io_mod.getIo());
    }

    pub fn snapshot(self: *Reducer, agent: Agent) Snapshot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.snapshotLocked(agent);
    }

    pub fn transition(
        self: *Reducer,
        agent: Agent,
        event: Event,
        attention_kind: ?hooks.AttentionKind,
    ) Update {
        return self.transitionWithToken(agent, event, attention_kind, null);
    }

    pub fn transitionWithToken(
        self: *Reducer,
        agent: Agent,
        event: Event,
        attention_kind: ?hooks.AttentionKind,
        attention_token: ?hooks.AttentionToken,
    ) Update {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        const state = self.statePtrLocked(agent) catch {
            const previous = self.snapshotLocked(agent);
            return .{
                .previous = previous,
                .current = reduceWithToken(previous, event, attention_kind, attention_token),
            };
        };
        const previous = state.*;
        state.* = reduceWithToken(previous, event, attention_kind, attention_token);
        return .{ .previous = previous, .current = state.* };
    }

    /// Closes one exact attention identity without publishing an external
    /// resolution. Cancellation and host teardown use this before releasing
    /// an abandoned approval so a registry snapshot copied earlier cannot
    /// reopen the child after its terminal lifecycle edge.
    pub fn closeAttentionToken(
        self: *Reducer,
        agent: Agent,
        attention_kind: hooks.AttentionKind,
        attention_token: hooks.AttentionToken,
    ) Update {
        return self.transitionWithToken(
            agent,
            .attention_closed,
            attention_kind,
            attention_token,
        );
    }

    fn snapshotLocked(self: *Reducer, agent: Agent) Snapshot {
        return switch (agent) {
            .main => self.main,
            .subagent_session => |session_id| self.subagent_sessions.get(session_id) orelse .{},
            .subagent_id => |subagent_id| self.subagent_ids.get(subagent_id) orelse .{},
            .anonymous_subagent => self.anonymous_subagent,
        };
    }

    fn statePtrLocked(self: *Reducer, agent: Agent) !*Snapshot {
        return switch (agent) {
            .main => &self.main,
            .subagent_session => |session_id| try self.subagentSessionPtrLocked(session_id),
            .subagent_id => |subagent_id| blk: {
                const alloc = self.alloc orelse return error.Uninitialized;
                const entry = try self.subagent_ids.getOrPut(alloc, subagent_id);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                break :blk entry.value_ptr;
            },
            .anonymous_subagent => &self.anonymous_subagent,
        };
    }

    fn subagentSessionPtrLocked(self: *Reducer, session_id: []const u8) !*Snapshot {
        if (self.subagent_sessions.getPtr(session_id)) |state| return state;
        const alloc = self.alloc orelse return error.Uninitialized;
        const owned_session_id = try alloc.dupe(u8, session_id);
        errdefer alloc.free(owned_session_id);
        const entry = try self.subagent_sessions.getOrPut(alloc, owned_session_id);
        if (entry.found_existing) {
            alloc.free(owned_session_id);
        } else {
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }
};

fn reduce(
    previous: Snapshot,
    event: Event,
    attention_kind: ?hooks.AttentionKind,
) Snapshot {
    return reduceWithToken(previous, event, attention_kind, null);
}

fn reduceWithToken(
    previous: Snapshot,
    event: Event,
    attention_kind: ?hooks.AttentionKind,
    attention_token: ?hooks.AttentionToken,
) Snapshot {
    var next = previous;
    switch (event) {
        .fx_started, .fx_stopped => return .{},
        .post_turn_end => {
            next.agent_state = .idle;
            next.attention_kind = null;
            next.attention_token = null;
        },
        .prompt_queued, .turn_started, .pre_tool_use, .stop => {
            next.agent_state = .working;
            next.attention_kind = null;
            next.attention_token = null;
        },
        .attention_required => {
            if (attention_token) |token| {
                if (attentionTokenClosed(previous, token)) return previous;
            }
            next.agent_state = .blocked;
            next.attention_kind = attention_kind;
            next.attention_token = attention_token;
        },
        .attention_resolved => {
            if (previous.agent_state != .blocked or previous.attention_kind != attention_kind) {
                return previous;
            }
            if (attention_token) |token| {
                const active = previous.attention_token orelse return previous;
                if (!std.mem.eql(u8, active[0..], token[0..])) return previous;
                rememberClosedAttentionToken(&next, token);
            }
            next.agent_state = .working;
            next.attention_kind = null;
            next.attention_token = null;
        },
        .attention_closed => {
            const kind = attention_kind orelse return previous;
            const token = attention_token orelse return previous;
            rememberClosedAttentionToken(&next, token);
            if (previous.agent_state == .blocked and
                previous.attention_kind == kind)
            {
                if (previous.attention_token) |active| {
                    if (std.mem.eql(u8, active[0..], token[0..])) {
                        next.agent_state = .working;
                        next.attention_kind = null;
                        next.attention_token = null;
                    }
                }
            }
        },
    }
    return next;
}

fn attentionTokenClosed(snapshot: Snapshot, token: hooks.AttentionToken) bool {
    for (snapshot.closed_attention_tokens) |maybe_closed| {
        const closed = maybe_closed orelse continue;
        if (std.mem.eql(u8, closed[0..], token[0..])) return true;
    }
    return false;
}

fn rememberClosedAttentionToken(snapshot: *Snapshot, token: hooks.AttentionToken) void {
    if (attentionTokenClosed(snapshot.*, token)) return;
    const index: usize = snapshot.closed_attention_next;
    snapshot.closed_attention_tokens[index] = token;
    snapshot.closed_attention_next =
        (index + 1) % snapshot.closed_attention_tokens.len;
}

test "lifecycle reducer carries attention through resolution and turn end" {
    var reducer = Reducer{};
    reducer.init(std.testing.allocator);
    defer reducer.deinit();

    try std.testing.expectEqual(AgentState.idle, reducer.snapshot(.main).agent_state);
    _ = reducer.transition(.main, .prompt_queued, null);
    try std.testing.expectEqual(AgentState.working, reducer.snapshot(.main).agent_state);
    _ = reducer.transition(.main, .attention_required, .permission);
    const blocked = reducer.snapshot(.main);
    try std.testing.expectEqual(AgentState.blocked, blocked.agent_state);
    try std.testing.expectEqual(hooks.AttentionKind.permission, blocked.attention_kind.?);
    _ = reducer.transition(.main, .attention_resolved, .permission);
    const resumed = reducer.snapshot(.main);
    try std.testing.expectEqual(AgentState.working, resumed.agent_state);
    try std.testing.expect(resumed.attention_kind == null);
    _ = reducer.transition(.main, .post_turn_end, null);
    try std.testing.expectEqual(AgentState.idle, reducer.snapshot(.main).agent_state);

    const child = Agent{ .subagent_session = "tokenized-child" };
    const first_token = [_]u8{0x11} ** 32;
    const next_token = [_]u8{0x22} ** 32;
    _ = reducer.transitionWithToken(child, .attention_required, .permission, first_token);
    _ = reducer.transitionWithToken(child, .attention_resolved, .permission, first_token);
    const delayed = reducer.transitionWithToken(
        child,
        .attention_required,
        .permission,
        first_token,
    );
    try std.testing.expect(!delayed.changed());
    try std.testing.expectEqual(AgentState.working, delayed.current.agent_state);
    const fresh = reducer.transitionWithToken(
        child,
        .attention_required,
        .permission,
        next_token,
    );
    try std.testing.expect(fresh.changed());
    try std.testing.expectEqual(AgentState.blocked, fresh.current.agent_state);

    const copied_before_cancel = [_]u8{0x33} ** 32;
    _ = reducer.closeAttentionToken(child, .permission, copied_before_cancel);
    _ = reducer.transition(child, .post_turn_end, null);
    const delayed_after_cancel = reducer.transitionWithToken(
        child,
        .attention_required,
        .permission,
        copied_before_cancel,
    );
    try std.testing.expect(!delayed_after_cancel.changed());
    try std.testing.expectEqual(AgentState.idle, delayed_after_cancel.current.agent_state);
}

test "lifecycle reducer ignores unmatched attention resolution" {
    var reducer = Reducer{};
    reducer.init(std.testing.allocator);
    defer reducer.deinit();

    _ = reducer.transition(.main, .prompt_queued, null);
    const absent = reducer.transition(.main, .attention_resolved, .question);
    try std.testing.expect(!absent.changed());
    try std.testing.expectEqual(AgentState.working, absent.current.agent_state);

    _ = reducer.transition(.main, .attention_required, .route_recovery);
    const wrong_kind = reducer.transition(.main, .attention_resolved, .question);
    try std.testing.expect(!wrong_kind.changed());
    try std.testing.expectEqual(AgentState.blocked, wrong_kind.current.agent_state);
    try std.testing.expectEqual(
        @as(?hooks.AttentionKind, .route_recovery),
        wrong_kind.current.attention_kind,
    );

    const matching = reducer.transition(.main, .attention_resolved, .route_recovery);
    try std.testing.expect(matching.changed());
    try std.testing.expectEqual(AgentState.working, matching.current.agent_state);
    try std.testing.expect(matching.current.attention_kind == null);
}

test "lifecycle reducer keeps main and subagent states independent" {
    var reducer = Reducer{};
    reducer.init(std.testing.allocator);
    defer reducer.deinit();

    const first = Agent{ .subagent_session = "child-a" };
    const second = Agent{ .subagent_session = "child-b" };
    _ = reducer.transition(first, .turn_started, null);
    _ = reducer.transition(second, .attention_required, .question);

    try std.testing.expectEqual(AgentState.idle, reducer.snapshot(.main).agent_state);
    try std.testing.expectEqual(AgentState.working, reducer.snapshot(first).agent_state);
    try std.testing.expectEqual(AgentState.blocked, reducer.snapshot(second).agent_state);
    try std.testing.expectEqual(hooks.AttentionKind.question, reducer.snapshot(second).attention_kind.?);
}

test "lifecycle reducer pairs a non-null attention kind only with blocked" {
    // fmx's decoder rejects a whole record whose snapshot carries an
    // attention kind without `blocked`, so this pairing is load-bearing on
    // the wire rather than merely tidy.
    const seeds = [_]Snapshot{
        .{},
        .{ .agent_state = .working },
        .{ .agent_state = .blocked, .attention_kind = .permission },
        .{ .agent_state = .blocked, .attention_kind = .question },
        .{ .agent_state = .blocked, .attention_kind = .route_recovery },
    };
    const kinds = [_]?hooks.AttentionKind{
        null,
        .permission,
        .question,
        .route_recovery,
    };

    for (seeds) |seed| {
        for (std.enums.values(Event)) |event| {
            for (kinds) |kind| {
                const current = reduce(seed, event, kind);
                if (current.attention_kind != null) {
                    try std.testing.expectEqual(AgentState.blocked, current.agent_state);
                }
                if (current.agent_state != .blocked) {
                    try std.testing.expect(current.attention_kind == null);
                }
            }
        }
    }

    // A blocked snapshot always names the kind that blocked it: an
    // `attention_required` with no kind would publish `blocked`/null and
    // lose which decision the human owes.
    for (seeds) |seed| {
        const blocked = reduce(seed, .attention_required, .question);
        try std.testing.expectEqual(AgentState.blocked, blocked.agent_state);
        try std.testing.expectEqual(hooks.AttentionKind.question, blocked.attention_kind.?);
    }
}
