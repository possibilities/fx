//! First-party lifecycle hook providers.
//!
//! ADE and Herdr are independent projections of one semantic lifecycle
//! reducer. Notification hooks live in `notifications` and keep sound policy
//! outside the Core hook harness.

const std = @import("std");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const hooks = @import("../core/hooks/hooks.zig");
const permission_request = @import("../core/permissions/permission_request.zig");
const herdr = @import("hooks/herdr.zig");

pub const ade_events = @import("hooks/ade_events.zig");
pub const lifecycle_state = @import("hooks/lifecycle_state.zig");
pub const notifications = @import("hooks/notifications.zig");
pub const Client = herdr.Client;

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Must run before the lifecycle runtime is frozen (currently the
        /// notification runtime performs the sole freeze right after this).
        pub fn configure(app: *App, active_session_id: ?[]const u8) !void {
            app.lifecycle_state.init(app.alloc);
            app.ade_events.initFromEnv(
                app.alloc,
                app.workspace_root,
                active_session_id,
                &app.lifecycle_state,
            );
            app.herdr.initFromEnv(app.alloc);
            if (app.herdr.enabled) {
                if (active_session_id) |session_id| {
                    app.herdr.reportSession(session_id);
                }
                app.herdr.reportState(.idle, null);
                app.herdr.announce();
            }
            if (app.ade_events.enabled or app.herdr.enabled) try register(app);
        }

        fn register(app: *App) !void {
            try app.lifecycle_runtime.registerTurnStarted(.{
                .name = "fx.lifecycle.turn_started",
                .ctx = app,
                .run = turnStartedHandler,
            });
            if (app.ade_events.enabled) {
                try app.lifecycle_runtime.registerPreToolUse(.{
                    .name = "fx.lifecycle.pre_tool_use",
                    .ctx = app,
                    .run = preToolUseHandler,
                });
                try app.lifecycle_runtime.registerStop(.{
                    .name = "fx.lifecycle.stop",
                    .ctx = app,
                    .run = stopHandler,
                });
            }
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.lifecycle.turn_end",
                .ctx = app,
                .run = postTurnEndHandler,
            });
            try app.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.lifecycle.attention_required",
                .ctx = app,
                .run = attentionRequiredHandler,
            });
            try app.lifecycle_runtime.registerAttentionResolved(.{
                .name = "fx.lifecycle.attention_resolved",
                .ctx = app,
                .run = attentionResolvedHandler,
            });
        }

        pub fn reportPromptQueued(app: *App) void {
            app.lifecycle_state.lockProjection();
            defer app.lifecycle_state.unlockProjection();
            _ = app.lifecycle_state.transition(.main, .prompt_queued, null);
            app.ade_events.reportPromptQueued();
        }

        pub fn reportPromptWorking(app: *App) void {
            if (app.herdr.enabled) app.herdr.reportState(.working, null);
        }

        pub fn reportSessionChanged(app: *App, session_id: ?[]const u8) void {
            {
                app.lifecycle_state.lockProjection();
                defer app.lifecycle_state.unlockProjection();
                app.ade_events.reportSessionChanged(session_id);
            }
            if (app.herdr.enabled) {
                if (session_id) |value| app.herdr.reportSession(value);
            }
        }

        pub fn prepareStopped(app: *App) void {
            app.lifecycle_state.lockProjection();
            defer app.lifecycle_state.unlockProjection();
            _ = app.lifecycle_state.transition(.main, .fx_stopped, null);
        }

        pub fn deinit(app: *App) void {
            app.lifecycle_state.deinit();
        }

        fn turnStartedHandler(
            raw: *anyopaque,
            input: hooks.TurnStartedInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            const agent = lifecycle_state.Agent.fromScope(input.invocation.scope) orelse return;
            app.lifecycle_state.lockProjection();
            defer app.lifecycle_state.unlockProjection();
            _ = app.lifecycle_state.transition(agent, .turn_started, null);
            app.ade_events.reportTurnStarted(input.invocation);
        }

        fn preToolUseHandler(
            raw: *anyopaque,
            input: hooks.PreToolUseInput,
        ) hooks.HandlerError!hooks.PreToolUseAction {
            const app: *App = @ptrCast(@alignCast(raw));
            const agent = lifecycle_state.Agent.fromScope(input.invocation.scope) orelse return .continue_;
            app.lifecycle_state.lockProjection();
            defer app.lifecycle_state.unlockProjection();
            _ = app.lifecycle_state.transition(agent, .pre_tool_use, null);
            app.ade_events.reportPreToolUse(input);
            return .continue_;
        }

        fn stopHandler(
            raw: *anyopaque,
            input: hooks.StopInput,
        ) hooks.HandlerError!hooks.StopAction {
            const app: *App = @ptrCast(@alignCast(raw));
            const agent = lifecycle_state.Agent.fromScope(input.invocation.scope) orelse return .allow;
            app.lifecycle_state.lockProjection();
            defer app.lifecycle_state.unlockProjection();
            _ = app.lifecycle_state.transition(agent, .stop, null);
            app.ade_events.reportStop(input);
            return .allow;
        }

        fn postTurnEndHandler(
            raw: *anyopaque,
            input: hooks.PostTurnEndInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            const agent = lifecycle_state.Agent.fromScope(input.invocation.scope) orelse return;
            {
                app.lifecycle_state.lockProjection();
                defer app.lifecycle_state.unlockProjection();
                _ = app.lifecycle_state.transition(agent, .post_turn_end, null);
                app.ade_events.reportPostTurnEnd(input);
            }
            if (app.herdr.enabled and input.invocation.scope.kind == .interactive) {
                app.herdr.reportState(.idle, null);
            }
        }

        fn attentionRequiredHandler(
            raw: *anyopaque,
            input: hooks.AttentionRequiredInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            const agent = lifecycle_state.Agent.fromScope(input.invocation.scope) orelse return;
            var projected = false;
            {
                app.lifecycle_state.lockProjection();
                defer app.lifecycle_state.unlockProjection();
                const update = app.lifecycle_state.transitionWithToken(
                    agent,
                    .attention_required,
                    input.kind,
                    input.attention_token,
                );
                if (update.changed()) {
                    app.ade_events.reportAttentionRequired(input);
                    projected = true;
                }
            }
            if (projected and app.herdr.enabled and input.presented_interactively) {
                app.herdr.reportState(.blocked, attentionStatus(input.kind));
            }
        }

        fn attentionResolvedHandler(
            raw: *anyopaque,
            input: hooks.AttentionResolvedInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            const agent = lifecycle_state.Agent.fromScope(input.invocation.scope) orelse return;
            var projected = false;
            {
                app.lifecycle_state.lockProjection();
                defer app.lifecycle_state.unlockProjection();
                const update = app.lifecycle_state.transitionWithToken(
                    agent,
                    .attention_resolved,
                    input.kind,
                    input.attention_token,
                );
                if (update.changed()) {
                    app.ade_events.reportAttentionResolved(input);
                    projected = true;
                }
            }
            if (projected and app.herdr.enabled and input.presented_interactively) {
                app.herdr.reportState(.working, null);
            }
        }

        fn attentionStatus(kind: hooks.AttentionKind) []const u8 {
            return switch (kind) {
                .permission => "permission",
                .question => "question",
                .route_recovery => "recovery",
            };
        }
    };
}

const RecordingClient = struct {
    const Report = struct {
        state: herdr.State,
        status: ?[]const u8,
        ade_event_count_seen: ?usize,
    };

    reports: [8]Report = undefined,
    report_count: usize = 0,
    enabled: bool = false,
    enable_on_init: bool = true,
    initialized: bool = false,
    announced: bool = false,
    session_id: ?[]const u8 = null,
    ade_event_count: ?*const usize = null,

    fn initFromEnv(self: *RecordingClient, _: std.mem.Allocator) void {
        self.initialized = true;
        self.enabled = self.enable_on_init;
    }

    fn reportSession(self: *RecordingClient, session_id: []const u8) void {
        self.session_id = session_id;
    }

    fn announce(self: *RecordingClient) void {
        self.announced = true;
    }

    fn reportState(self: *RecordingClient, state: herdr.State, status: ?[]const u8) void {
        self.reports[self.report_count] = .{
            .state = state,
            .status = status,
            .ade_event_count_seen = if (self.ade_event_count) |count| count.* else null,
        };
        self.report_count += 1;
    }
};

const RecordingAdeClient = struct {
    const Event = enum {
        fx_started,
        prompt_queued,
        turn_started,
        pre_tool_use,
        stop,
        post_turn_end,
        attention_required,
        attention_resolved,
    };

    events: [16]Event = undefined,
    snapshots: [16]lifecycle_state.Snapshot = undefined,
    event_count: usize = 0,
    enabled: bool = false,
    enable_on_init: bool = true,
    initialized: bool = false,
    lifecycle: ?*lifecycle_state.Reducer = null,
    reported_session: ?[]const u8 = null,

    fn initFromEnv(
        self: *RecordingAdeClient,
        _: std.mem.Allocator,
        _: []const u8,
        _: ?[]const u8,
        lifecycle: *lifecycle_state.Reducer,
    ) void {
        self.initialized = true;
        self.enabled = self.enable_on_init;
        self.lifecycle = lifecycle;
        if (self.enabled) self.record(.fx_started, .main);
    }

    fn reportSessionChanged(self: *RecordingAdeClient, session_id: ?[]const u8) void {
        self.reported_session = session_id;
    }

    fn reportPromptQueued(self: *RecordingAdeClient) void {
        if (self.enabled) self.record(.prompt_queued, .main);
    }

    fn reportTurnStarted(self: *RecordingAdeClient, invocation: hooks.Invocation) void {
        if (self.enabled) self.recordInvocation(.turn_started, invocation);
    }

    fn reportPreToolUse(self: *RecordingAdeClient, input: hooks.PreToolUseInput) void {
        if (self.enabled) self.recordInvocation(.pre_tool_use, input.invocation);
    }

    fn reportStop(self: *RecordingAdeClient, input: hooks.StopInput) void {
        if (self.enabled) self.recordInvocation(.stop, input.invocation);
    }

    fn reportPostTurnEnd(self: *RecordingAdeClient, input: hooks.PostTurnEndInput) void {
        if (self.enabled) self.recordInvocation(.post_turn_end, input.invocation);
    }

    fn reportAttentionRequired(self: *RecordingAdeClient, input: hooks.AttentionRequiredInput) void {
        if (self.enabled) self.recordInvocation(.attention_required, input.invocation);
    }

    fn reportAttentionResolved(self: *RecordingAdeClient, input: hooks.AttentionResolvedInput) void {
        if (self.enabled) self.recordInvocation(.attention_resolved, input.invocation);
    }

    fn recordInvocation(self: *RecordingAdeClient, event: Event, invocation: hooks.Invocation) void {
        const agent = lifecycle_state.Agent.fromScope(invocation.scope) orelse return;
        self.record(event, agent);
    }

    fn record(self: *RecordingAdeClient, event: Event, agent: lifecycle_state.Agent) void {
        self.events[self.event_count] = event;
        self.snapshots[self.event_count] = if (self.lifecycle) |lifecycle|
            lifecycle.snapshot(agent)
        else
            .{};
        self.event_count += 1;
    }
};

test "lifecycle coordinator projects full ADE state and interactive Herdr state independently" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "/tmp/workspace",
        lifecycle_runtime: hooks.Runtime,
        lifecycle_state: lifecycle_state.Reducer = .{},
        ade_events: RecordingAdeClient = .{},
        herdr: RecordingClient = .{},
    };
    const Provider = Runtime(TestApp);

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();
    defer Provider.deinit(&app);

    try Provider.configure(&app, "session-42");
    const view = app.lifecycle_runtime.freeze();
    try std.testing.expect(app.herdr.initialized);
    try std.testing.expect(app.ade_events.initialized);
    try std.testing.expect(app.herdr.announced);
    try std.testing.expectEqualStrings("session-42", app.herdr.session_id orelse return error.TestExpectedEqual);
    try std.testing.expect(view.hasPostTurnEnd());
    try std.testing.expect(view.hasAttentionRequired());
    try std.testing.expect(view.hasAttentionResolved());

    app.herdr.ade_event_count = &app.ade_events.event_count;
    Provider.reportPromptQueued(&app);
    Provider.reportPromptWorking(&app);
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.ask),
        .outcome = .completed,
    });
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.interactive),
        .outcome = .completed,
    });
    const child_attention_token = [_]u8{0x41} ** 32;
    view.runAttentionRequired(.{
        .invocation = testInvocation(.subagent),
        .kind = .permission,
        .presented_interactively = true,
        .attention_token = child_attention_token,
    });
    view.runAttentionResolved(.{
        .invocation = testInvocation(.subagent),
        .kind = .permission,
        .presented_interactively = true,
        .attention_token = child_attention_token,
    });
    // Models a registry snapshot copied before resolution and dispatched
    // afterward. The delayed edge must not reopen either projection.
    view.runAttentionRequired(.{
        .invocation = testInvocation(.subagent),
        .kind = .permission,
        .presented_interactively = true,
        .attention_token = child_attention_token,
    });
    view.runAttentionRequired(.{
        .invocation = testInvocation(.interactive),
        .kind = .route_recovery,
        .presented_interactively = true,
    });
    view.runAttentionResolved(.{
        .invocation = testInvocation(.interactive),
        .kind = .route_recovery,
        .presented_interactively = true,
    });

    try std.testing.expectEqual(@as(usize, 7), app.herdr.report_count);
    try expectReport(app.herdr.reports[0], .idle, null);
    try expectReport(app.herdr.reports[1], .working, null);
    try expectReport(app.herdr.reports[2], .idle, null);
    try expectReport(app.herdr.reports[3], .blocked, "permission");
    try expectReport(app.herdr.reports[4], .working, null);
    try expectReport(app.herdr.reports[5], .blocked, "recovery");
    try expectReport(app.herdr.reports[6], .working, null);
    try std.testing.expectEqual(@as(usize, 7), app.ade_events.event_count);
    try std.testing.expectEqual(RecordingAdeClient.Event.fx_started, app.ade_events.events[0]);
    try std.testing.expectEqual(RecordingAdeClient.Event.prompt_queued, app.ade_events.events[1]);
    try std.testing.expectEqual(RecordingAdeClient.Event.post_turn_end, app.ade_events.events[2]);
    try std.testing.expectEqual(RecordingAdeClient.Event.attention_required, app.ade_events.events[3]);
    try std.testing.expectEqual(RecordingAdeClient.Event.attention_resolved, app.ade_events.events[4]);
    try std.testing.expectEqual(RecordingAdeClient.Event.attention_required, app.ade_events.events[5]);
    try std.testing.expectEqual(RecordingAdeClient.Event.attention_resolved, app.ade_events.events[6]);
    try std.testing.expectEqual(lifecycle_state.AgentState.idle, app.ade_events.snapshots[0].agent_state);
    try std.testing.expectEqual(lifecycle_state.AgentState.working, app.ade_events.snapshots[1].agent_state);
    try std.testing.expectEqual(lifecycle_state.AgentState.idle, app.ade_events.snapshots[2].agent_state);
    try std.testing.expectEqual(lifecycle_state.AgentState.blocked, app.ade_events.snapshots[3].agent_state);
    try std.testing.expectEqual(hooks.AttentionKind.permission, app.ade_events.snapshots[3].attention_kind.?);
    try std.testing.expectEqual(lifecycle_state.AgentState.working, app.ade_events.snapshots[4].agent_state);
    try std.testing.expect(app.ade_events.snapshots[4].attention_kind == null);
    try std.testing.expectEqual(@as(?usize, 2), app.herdr.reports[1].ade_event_count_seen);
    try std.testing.expectEqual(lifecycle_state.AgentState.working, app.lifecycle_state.snapshot(.main).agent_state);
    try std.testing.expectEqual(
        lifecycle_state.AgentState.working,
        app.lifecycle_state.snapshot(.{ .subagent_session = "session" }).agent_state,
    );
}

test "lifecycle coordinator suppresses unmatched attention resolution for ADE and Herdr" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "/tmp/workspace",
        lifecycle_runtime: hooks.Runtime,
        lifecycle_state: lifecycle_state.Reducer = .{},
        ade_events: RecordingAdeClient = .{},
        herdr: RecordingClient = .{},
    };
    const Provider = Runtime(TestApp);

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();
    defer Provider.deinit(&app);
    try Provider.configure(&app, "session-42");
    const view = app.lifecycle_runtime.freeze();

    Provider.reportPromptQueued(&app);
    Provider.reportPromptWorking(&app);
    const ade_count_before = app.ade_events.event_count;
    const herdr_count_before = app.herdr.report_count;
    view.runAttentionResolved(.{
        .invocation = testInvocation(.interactive),
        .kind = .question,
        .presented_interactively = true,
    });

    try std.testing.expectEqual(ade_count_before, app.ade_events.event_count);
    try std.testing.expectEqual(herdr_count_before, app.herdr.report_count);
    try std.testing.expectEqual(
        lifecycle_state.AgentState.working,
        app.lifecycle_state.snapshot(.main).agent_state,
    );

    view.runAttentionRequired(.{
        .invocation = testInvocation(.interactive),
        .kind = .question,
        .presented_interactively = true,
    });
    view.runAttentionResolved(.{
        .invocation = testInvocation(.interactive),
        .kind = .question,
        .presented_interactively = true,
    });
    try std.testing.expectEqual(ade_count_before + 2, app.ade_events.event_count);
    try std.testing.expectEqual(herdr_count_before + 2, app.herdr.report_count);
    try std.testing.expectEqual(
        RecordingAdeClient.Event.attention_required,
        app.ade_events.events[ade_count_before],
    );
    try std.testing.expectEqual(
        RecordingAdeClient.Event.attention_resolved,
        app.ade_events.events[ade_count_before + 1],
    );
    try expectReport(app.herdr.reports[herdr_count_before], .blocked, "question");
    try expectReport(app.herdr.reports[herdr_count_before + 1], .working, null);
}

test "terminal turn closure clears unresolved attention without a synthetic resolution" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "/tmp/workspace",
        lifecycle_runtime: hooks.Runtime,
        lifecycle_state: lifecycle_state.Reducer = .{},
        ade_events: RecordingAdeClient = .{},
        herdr: RecordingClient = .{},
    };
    const Provider = Runtime(TestApp);

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();
    defer Provider.deinit(&app);
    try Provider.configure(&app, "session-42");
    const view = app.lifecycle_runtime.freeze();

    Provider.reportPromptQueued(&app);
    Provider.reportPromptWorking(&app);
    view.runAttentionRequired(.{
        .invocation = testInvocation(.interactive),
        .kind = .question,
        .presented_interactively = true,
    });
    view.runPostTurnEnd(.{
        .invocation = testInvocation(.interactive),
        .outcome = .interrupted,
        .provider_disposition = .interrupted,
    });

    try std.testing.expectEqual(@as(usize, 4), app.ade_events.event_count);
    try std.testing.expectEqual(
        RecordingAdeClient.Event.attention_required,
        app.ade_events.events[2],
    );
    try std.testing.expectEqual(
        RecordingAdeClient.Event.post_turn_end,
        app.ade_events.events[3],
    );
    try std.testing.expectEqual(@as(usize, 4), app.herdr.report_count);
    try expectReport(app.herdr.reports[2], .blocked, "question");
    try expectReport(app.herdr.reports[3], .idle, null);
    const snapshot = app.lifecycle_state.snapshot(.main);
    try std.testing.expectEqual(lifecycle_state.AgentState.idle, snapshot.agent_state);
    try std.testing.expect(snapshot.attention_kind == null);
}

test "accepted decision projects resolution before an immediately finishing worker" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "/tmp/workspace",
        lifecycle_runtime: hooks.Runtime,
        lifecycle_state: lifecycle_state.Reducer = .{},
        ade_events: RecordingAdeClient = .{},
        herdr: RecordingClient = .{},
    };
    const Provider = Runtime(TestApp);
    const Waiter = struct {
        worker: *worker_runtime.WorkerRuntime,
        view: hooks.RuntimeView,
        completed: *std.atomic.Value(bool),
        decision: ?@import("../core/shared/types.zig").ToolPermissionDecision = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            var response = self.worker.requestPermissionBlocking(
                std.testing.allocator,
                .{ .label = "finish immediately" },
            ) catch |err| {
                self.err = err;
                self.completed.store(true, .seq_cst);
                return;
            };
            defer response.deinit();
            self.decision = response.decision;
            self.worker.finishProcessing();
            var stop = self.view.runStop(std.testing.allocator, .{
                .invocation = testInvocation(.interactive),
                .step_index = 1,
                .assistant_text = "done",
                .provider_disposition = .completed,
                .can_continue = false,
            });
            stop.deinit(std.testing.allocator);
            self.view.runPostTurnEnd(.{
                .invocation = testInvocation(.interactive),
                .outcome = .completed,
                .provider_disposition = .completed,
            });
            self.completed.store(true, .seq_cst);
        }
    };
    const Observer = struct {
        view: hooks.RuntimeView,
        entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        turn_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        fn interface(self: *@This()) worker_runtime.DecisionObserver {
            return .{
                .context = self,
                .observe_fn = observe,
            };
        }

        fn observe(raw: *anyopaque, turn_id: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.turn_id.store(turn_id, .seq_cst);
            self.view.runAttentionResolved(.{
                .invocation = testInvocation(.interactive),
                .kind = .permission,
                .presented_interactively = true,
            });
            self.entered.store(true, .seq_cst);
            while (!self.release.load(.seq_cst)) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }
    };
    const Submitter = struct {
        worker: *worker_runtime.WorkerRuntime,
        request_id: u64,
        observer: *Observer,
        result: ?worker_runtime.PermissionSubmissionResult = null,

        fn run(self: *@This()) void {
            self.result = self.worker.submitPermissionResponseObserved(
                self.request_id,
                permission_request.OwnedPermissionResponse.init(
                    std.testing.allocator,
                    .once,
                    null,
                ),
                self.observer.interface(),
            );
        }
    };

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();
    defer Provider.deinit(&app);
    try Provider.configure(&app, "session-42");
    const view = app.lifecycle_runtime.freeze();
    Provider.reportPromptQueued(&app);
    Provider.reportPromptWorking(&app);

    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(std.testing.allocator);
    worker.worker_processing = true;
    worker.active_turn_id = 42;
    var completed = std.atomic.Value(bool).init(false);
    var waiter = Waiter{
        .worker = &worker,
        .view = view,
        .completed = &completed,
    };
    const waiter_thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    var request_id: u64 = 0;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var snapshot = try worker.snapshotState(std.testing.allocator);
        defer snapshot.deinit(std.testing.allocator);
        if (snapshot.pending_permission_request) |request| {
            request_id = request.id;
            break;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expect(request_id != 0);
    view.runAttentionRequired(.{
        .invocation = testInvocation(.interactive),
        .kind = .permission,
        .presented_interactively = true,
    });

    var observer = Observer{ .view = view };
    var submitter = Submitter{
        .worker = &worker,
        .request_id = request_id,
        .observer = &observer,
    };
    const submitter_thread = try std.Thread.spawn(.{}, Submitter.run, .{&submitter});
    while (!observer.entered.load(.seq_cst)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }

    try std.testing.expect(!completed.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 42), observer.turn_id.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 4), app.ade_events.event_count);
    try std.testing.expectEqual(
        RecordingAdeClient.Event.attention_resolved,
        app.ade_events.events[3],
    );
    try std.testing.expectEqual(
        lifecycle_state.AgentState.working,
        app.lifecycle_state.snapshot(.main).agent_state,
    );
    try expectReport(app.herdr.reports[3], .working, null);

    observer.release.store(true, .seq_cst);
    submitter_thread.join();
    waiter_thread.join();

    try std.testing.expectEqual(
        worker_runtime.PermissionSubmissionResult.accepted,
        submitter.result.?,
    );
    try std.testing.expect(waiter.err == null);
    try std.testing.expectEqual(
        @import("../core/shared/types.zig").ToolPermissionDecision.once,
        waiter.decision.?,
    );
    try std.testing.expectEqual(@as(usize, 6), app.ade_events.event_count);
    try std.testing.expectEqual(RecordingAdeClient.Event.stop, app.ade_events.events[4]);
    try std.testing.expectEqual(RecordingAdeClient.Event.post_turn_end, app.ade_events.events[5]);
    try std.testing.expectEqual(
        lifecycle_state.AgentState.idle,
        app.lifecycle_state.snapshot(.main).agent_state,
    );
    try std.testing.expectEqual(@as(usize, 5), app.herdr.report_count);
    try expectReport(app.herdr.reports[4], .idle, null);
}

test "enabling either lifecycle projection does not control the other" {
    const HerdrOnlyApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "/tmp/workspace",
        lifecycle_runtime: hooks.Runtime,
        lifecycle_state: lifecycle_state.Reducer = .{},
        ade_events: RecordingAdeClient = .{ .enable_on_init = false },
        herdr: RecordingClient = .{},
    };
    var herdr_only = HerdrOnlyApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer herdr_only.lifecycle_runtime.deinit();
    defer Runtime(HerdrOnlyApp).deinit(&herdr_only);
    try Runtime(HerdrOnlyApp).configure(&herdr_only, "session-42");
    Runtime(HerdrOnlyApp).reportPromptQueued(&herdr_only);
    Runtime(HerdrOnlyApp).reportPromptWorking(&herdr_only);
    try std.testing.expectEqual(@as(usize, 0), herdr_only.ade_events.event_count);
    try std.testing.expectEqual(@as(usize, 2), herdr_only.herdr.report_count);
    try expectReport(herdr_only.herdr.reports[1], .working, null);

    const AdeOnlyApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "/tmp/workspace",
        lifecycle_runtime: hooks.Runtime,
        lifecycle_state: lifecycle_state.Reducer = .{},
        ade_events: RecordingAdeClient = .{},
        herdr: RecordingClient = .{ .enable_on_init = false },
    };
    var ade_only = AdeOnlyApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer ade_only.lifecycle_runtime.deinit();
    defer Runtime(AdeOnlyApp).deinit(&ade_only);
    try Runtime(AdeOnlyApp).configure(&ade_only, "session-42");
    Runtime(AdeOnlyApp).reportPromptQueued(&ade_only);
    Runtime(AdeOnlyApp).reportPromptWorking(&ade_only);
    try std.testing.expectEqual(@as(usize, 2), ade_only.ade_events.event_count);
    try std.testing.expectEqual(lifecycle_state.AgentState.working, ade_only.ade_events.snapshots[1].agent_state);
    try std.testing.expectEqual(@as(usize, 0), ade_only.herdr.report_count);
}

test "disabled lifecycle projections register no lifecycle hooks" {
    const TestApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "/tmp/workspace",
        lifecycle_runtime: hooks.Runtime,
        lifecycle_state: lifecycle_state.Reducer = .{},
        ade_events: RecordingAdeClient = .{ .enable_on_init = false },
        herdr: RecordingClient = .{ .enable_on_init = false },
    };

    var app = TestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    defer app.lifecycle_runtime.deinit();
    defer Runtime(TestApp).deinit(&app);

    try Runtime(TestApp).configure(&app, "session-42");
    const view = app.lifecycle_runtime.freeze();
    try std.testing.expect(app.herdr.initialized);
    try std.testing.expect(app.ade_events.initialized);
    try std.testing.expect(!app.herdr.announced);
    try std.testing.expect(app.herdr.session_id == null);
    try std.testing.expectEqual(@as(usize, 0), app.herdr.report_count);
    try std.testing.expect(!view.hasPostTurnEnd());
    try std.testing.expect(!view.hasAttentionRequired());
    try std.testing.expect(!view.hasAttentionResolved());
}

fn testInvocation(kind: hooks.ScopeKind) hooks.Invocation {
    return .{
        .scope = .{
            .kind = kind,
            .workspace_root = "/tmp/workspace",
            .session_id = "session",
        },
        .turn_id = 42,
    };
}

fn expectReport(actual: RecordingClient.Report, state: herdr.State, status: ?[]const u8) !void {
    try std.testing.expectEqual(state, actual.state);
    if (status) |expected| {
        try std.testing.expectEqualStrings(expected, actual.status orelse return error.TestExpectedEqual);
    } else {
        try std.testing.expect(actual.status == null);
    }
}
