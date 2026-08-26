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
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        const state = self.statePtrLocked(agent) catch {
            const previous = self.snapshotLocked(agent);
            return .{
                .previous = previous,
                .current = reduce(previous, event, attention_kind),
            };
        };
        const previous = state.*;
        state.* = reduce(previous, event, attention_kind);
        return .{ .previous = previous, .current = state.* };
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
    _ = previous;
    return switch (event) {
        .fx_started, .post_turn_end, .fx_stopped => .{},
        .prompt_queued, .turn_started, .pre_tool_use, .stop, .attention_resolved => .{
            .agent_state = .working,
        },
        .attention_required => .{
            .agent_state = .blocked,
            .attention_kind = attention_kind,
        },
    };
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
