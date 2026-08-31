const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_codec = @import("../session/session_codec.zig");
const session_layout = @import("../session/session_layout.zig");
const session_store = @import("../session/session_store.zig");
const protocol = @import("launch_admission_final.zig");
const ledger_mod = @import("launch_admission_final_ledger.zig");
const child_runtime = @import("launch_admission_final_runtime.zig");

const Allocator = std.mem.Allocator;

pub const SpawnMode = enum {
    initial,
    /// The caller has exact external proof that the prior child process ended.
    /// Recovery resumes a durable active Conversation. If an originally fresh
    /// launch never created one, it reuses the retained fresh reservation.
    recover_after_definitive_end,
};

pub const PreparedLaunch = struct {
    alloc: Allocator,
    ledger: ledger_mod.Ledger,
    accepted: ledger_mod.Loaded,
    replayed: bool,

    /// Reserves a valid fresh Conversation identity before any process effect.
    /// Exact resume uses the requested identity and rejects substitution.
    pub fn prepare(alloc: Allocator, request: protocol.LaunchRequest) !PreparedLaunch {
        var ledger = try ledger_mod.Ledger.open(alloc, request.state_root, .{});
        errdefer ledger.deinit();
        const candidate = switch (request.resume_target) {
            .fresh => try session_layout.generateSessionId(alloc),
            .exact => |conversation_id| try alloc.dupe(u8, conversation_id),
        };
        defer alloc.free(candidate);
        try session_layout.validateSessionId(candidate);
        const mutation = try ledger.acceptLaunchObserved(request, candidate);
        const accepted = mutation.loaded;
        const replayed = !mutation.newly_accepted;
        return .{
            .alloc = alloc,
            .ledger = ledger,
            .accepted = accepted,
            .replayed = replayed,
        };
    }

    pub fn deinit(self: *PreparedLaunch) void {
        self.accepted.deinit();
        self.ledger.deinit();
        self.* = undefined;
    }

    pub fn launchReceipt(
        self: *const PreparedLaunch,
        request_id: []const u8,
    ) protocol.LaunchReceipt {
        return self.accepted.record.launchReceipt(request_id);
    }

    pub fn cancel(
        self: *PreparedLaunch,
        request: protocol.AdmissionCancelRequest,
    ) !ledger_mod.AdmissionMutation {
        return self.ledger.cancel(request);
    }

    pub fn retained(self: *PreparedLaunch) !ledger_mod.Loaded {
        return (try self.ledger.load(self.accepted.record.admission_key)) orelse
            error.LaunchNotFound;
    }

    pub fn acknowledgeFinal(
        self: *PreparedLaunch,
        acknowledgement: protocol.FinalReceiptAcknowledgement,
    ) !ledger_mod.Loaded {
        return self.ledger.acknowledgeFinal(acknowledgement);
    }

    /// Constructs an ordinary Fx invocation. This is not a new command or
    /// transport: state root and name remain native global launch controls,
    /// while exact/recovery identity uses the one existing resume path.
    pub fn buildFxInvocation(
        self: *PreparedLaunch,
        executable: []const u8,
        remaining_global_args: []const []const u8,
        mode: SpawnMode,
    ) !FxInvocation {
        var current = try self.retained();
        defer current.deinit();
        const resume_id: ?[]const u8 = switch (mode) {
            .initial => switch (current.record.resume_target) {
                .fresh => null,
                .exact => |conversation_id| conversation_id,
            },
            .recover_after_definitive_end => switch (current.record.resume_target) {
                .exact => current.record.active_conversation_id,
                .fresh => if (try durableConversationExists(
                    self.alloc,
                    current.record.state_root,
                    current.record.directory,
                    current.record.active_conversation_id,
                ))
                    current.record.active_conversation_id
                else if (std.mem.eql(
                    u8,
                    current.record.active_conversation_id,
                    current.record.initial_conversation_id,
                ))
                    null
                else
                    return error.LaunchConversationUnavailable,
            },
        };

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();
        const scratch = arena.allocator();
        const count = 5 + remaining_global_args.len + (if (resume_id == null) @as(usize, 0) else 2);
        const argv = try scratch.alloc([]const u8, count);
        var index: usize = 0;
        argv[index] = try scratch.dupe(u8, executable);
        index += 1;
        argv[index] = "--state-dir";
        index += 1;
        argv[index] = try scratch.dupe(u8, current.record.state_root);
        index += 1;
        argv[index] = "--name";
        index += 1;
        argv[index] = try scratch.dupe(u8, current.record.conversation_name);
        index += 1;
        for (remaining_global_args) |arg| {
            argv[index] = try scratch.dupe(u8, arg);
            index += 1;
        }
        if (resume_id) |conversation_id| {
            argv[index] = "resume";
            index += 1;
            argv[index] = try scratch.dupe(u8, conversation_id);
            index += 1;
        }
        std.debug.assert(index == count);

        var environment = try io_mod.cloneEnvironMap(self.alloc);
        errdefer environment.deinit();
        try child_runtime.applyChildEnvironment(
            &environment,
            current.record,
            resume_id orelse current.record.initial_conversation_id,
        );
        const cwd = try scratch.dupe(u8, current.record.directory);
        return .{
            .arena = arena,
            .environment = environment,
            .argv = argv,
            .cwd = cwd,
        };
    }
};

/// Uses Fx's existing read-only session authority rather than directory
/// presence. A prepared schema-v3 orphan is not a durable Conversation, while
/// malformed or unavailable state remains an error instead of silently
/// selecting a second prompt path.
fn durableConversationExists(
    alloc: Allocator,
    state_root: []const u8,
    workspace_root: []const u8,
    conversation_id: []const u8,
) !bool {
    var store = try session_store.Store.initReadOnlyFromHome(
        alloc,
        state_root,
        workspace_root,
    );
    defer store.deinit(alloc);
    var state = store.loadReadOnly(alloc, conversation_id) catch |err| switch (err) {
        error.SessionNotFound => return false,
        else => return err,
    };
    state.deinit(alloc);
    return true;
}

pub const FxInvocation = struct {
    arena: std.heap.ArenaAllocator,
    environment: std.process.Environ.Map,
    argv: []const []const u8,
    cwd: []const u8,

    pub fn deinit(self: *FxInvocation) void {
        self.environment.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const NativeSupervisor = struct {
    prepared: *PreparedLaunch,
    child: ?std.process.Child = null,
    pending_terminal: ?PendingTerminalOutcome = null,
    terminal_message: [256]u8 = undefined,
    terminal_recorded: bool = false,
    now_ms: *const fn () i64 = io_mod.milliTimestamp,

    /// Spawns the child only after the launch record and reserved identity are
    /// durable. A replayed, outcome-unknown launch requires explicit definitive
    /// end proof before it can resume, preventing a second live process.
    pub fn spawn(
        prepared: *PreparedLaunch,
        invocation: *const FxInvocation,
        mode: SpawnMode,
    ) !NativeSupervisor {
        var current = try prepared.retained();
        defer current.deinit();
        if (current.record.final_receipt != null) {
            return .{ .prepared = prepared, .terminal_recorded = true };
        }
        if (current.record.decision) |decision| switch (decision.decision) {
            .cancelled_before_start => return error.LaunchCancelledBeforeStart,
            .admitted => {},
        };
        if (prepared.replayed and mode == .initial) return error.LaunchRecoveryPending;

        const child = std.process.spawn(io_mod.getIo(), .{
            .argv = invocation.argv,
            .cwd = .{ .path = invocation.cwd },
            .environ_map = &invocation.environment,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| {
            var supervisor = NativeSupervisor{ .prepared = prepared };
            const message = std.fmt.bufPrint(
                &supervisor.terminal_message,
                "child exec failed: {s}",
                .{@errorName(err)},
            ) catch fallback_message: {
                const fallback = "child exec failed";
                @memcpy(supervisor.terminal_message[0..fallback.len], fallback);
                break :fallback_message supervisor.terminal_message[0..fallback.len];
            };
            supervisor.pending_terminal = .{ .exec_failed = message.len };
            return supervisor;
        };
        return .{ .prepared = prepared, .child = child };
    }

    /// Reaps the child, durably records its process-level terminal outcome, and
    /// leaves that receipt available through `PreparedLaunch.retained` until an
    /// exact acknowledgement is committed.
    pub fn wait(self: *NativeSupervisor) !ledger_mod.Loaded {
        if (self.terminal_recorded) return self.prepared.retained();
        if (self.pending_terminal != null) return self.persistPendingTerminal();
        const child = if (self.child) |*value| value else return error.ChildNotRunning;
        // A failed wait is not proof that the child ended. Retain the handle
        // and leave the durable receipt open rather than inventing a terminal
        // outcome while the process may still be live.
        const term = try child.wait(io_mod.getIo());
        switch (term) {
            .exited => |code| self.pending_terminal = .{ .exited = code },
            .signal => |signal| self.pending_terminal = .{
                .signalled = @intCast(@intFromEnum(signal)),
            },
            // A stopped process can still continue and produce a later exit.
            // Keep its handle and never publish a terminal receipt for it.
            .stopped => return error.ChildStopped,
            .unknown => |status| {
                const message = std.fmt.bufPrint(
                    &self.terminal_message,
                    "child returned unknown wait status {d}",
                    .{status},
                ) catch fallback_message: {
                    const fallback = "child returned an unknown wait status";
                    @memcpy(self.terminal_message[0..fallback.len], fallback);
                    break :fallback_message self.terminal_message[0..fallback.len];
                };
                self.pending_terminal = .{ .exec_failed = message.len };
            },
        }
        self.child = null;
        return self.persistPendingTerminal();
    }

    fn persistPendingTerminal(self: *NativeSupervisor) !ledger_mod.Loaded {
        const pending = self.pending_terminal orelse return error.ChildNotRunning;
        const outcome: protocol.Outcome = switch (pending) {
            .exited => |code| .{ .exited = code },
            .signalled => |signal| .{ .signalled = signal },
            .exec_failed => |len| .{ .exec_failed = self.terminal_message[0..len] },
        };
        const recorded = try recordFinalAt(self.prepared, outcome, self.now_ms());
        self.pending_terminal = null;
        self.terminal_recorded = true;
        return recorded;
    }
};

const PendingTerminalOutcome = union(enum) {
    exited: u8,
    signalled: u8,
    exec_failed: usize,
};

fn recordFinalAt(
    prepared: *PreparedLaunch,
    outcome: protocol.Outcome,
    timestamp_ms: i64,
) !ledger_mod.Loaded {
    var timestamp_buffer: [24]u8 = undefined;
    const observed_at = try protocol.formatTimestamp(
        &timestamp_buffer,
        timestamp_ms,
    );
    return prepared.ledger.recordFinal(
        prepared.accepted.record.admission_key,
        prepared.accepted.record.launch_digest,
        prepared.accepted.record.launch_id,
        outcome,
        observed_at,
    );
}

fn testRequest(
    root: []const u8,
    admission_key: []const u8,
    resume_target: protocol.Resume,
    digest: *[64]u8,
) !protocol.LaunchRequest {
    var request: protocol.LaunchRequest = .{
        .admission_key = admission_key,
        .conversation_name = "Native supervisor fixture",
        .directory = root,
        .effort = "medium",
        .initial_work_digest = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .launch_digest = digest,
        .launch_id = "native-launch",
        .model = "fixture/model",
        .remaining_launch_controls_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .request_id = "native-request",
        .resume_target = resume_target,
        .state_root = root,
    };
    digest.* = try protocol.computeLaunchDigest(std.testing.allocator, request);
    request.launch_digest = digest;
    return request;
}

fn createTestDurableConversation(
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

var stable_launcher_test_environ: ?*std.process.Environ.Map = null;

fn installLauncherTestEnviron() !void {
    if (stable_launcher_test_environ == null) {
        const alloc = std.heap.page_allocator;
        const map = try alloc.create(std.process.Environ.Map);
        map.* = std.process.Environ.Map.init(alloc);
        stable_launcher_test_environ = map;
    }
    io_mod.setEnvironMap(stable_launcher_test_environ.?);
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

fn launcherTestTimestampMs() i64 {
    return 0;
}

test "native launch preparation reserves fresh identity and exact resume before exec" {
    const alloc = std.testing.allocator;
    try installLauncherTestEnviron();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var fresh_digest: [64]u8 = undefined;
    const fresh_request = try testRequest(root, "fresh-attempt", .fresh, &fresh_digest);
    var fresh = try PreparedLaunch.prepare(alloc, fresh_request);
    defer fresh.deinit();
    try session_layout.validateSessionId(fresh.accepted.record.initial_conversation_id);
    try std.testing.expect(fresh.accepted.record.initial_conversation_id.len > 16);

    var exact_digest: [64]u8 = undefined;
    const exact_id = "1788000000000-1788000000000000000-abcd1234";
    const exact_request = try testRequest(
        root,
        "exact-attempt",
        .{ .exact = exact_id },
        &exact_digest,
    );
    var exact = try PreparedLaunch.prepare(alloc, exact_request);
    defer exact.deinit();
    try std.testing.expectEqualStrings(exact_id, exact.accepted.record.initial_conversation_id);

    var invocation = try exact.buildFxInvocation("/path/to/fx", &.{"--record"}, .initial);
    defer invocation.deinit();
    try expectArgv(&.{
        "/path/to/fx",
        "--state-dir",
        root,
        "--name",
        "Native supervisor fixture",
        "--record",
        "resume",
        exact_id,
    }, invocation.argv);
    try std.testing.expectEqualStrings(
        exact_id,
        invocation.environment.get(child_runtime.conversation_id_env).?,
    );
}

test "native prepared-fresh recovery reuses its reservation before any durable Conversation exists" {
    const alloc = std.testing.allocator;
    try installLauncherTestEnviron();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var digest: [64]u8 = undefined;
    const request = try testRequest(root, "prepared-fresh-attempt", .fresh, &digest);
    var initial_id: []u8 = undefined;
    {
        var initial = try PreparedLaunch.prepare(alloc, request);
        defer initial.deinit();
        initial_id = try alloc.dupe(u8, initial.accepted.record.initial_conversation_id);
    }
    defer alloc.free(initial_id);

    var recovered = try PreparedLaunch.prepare(alloc, request);
    defer recovered.deinit();
    try std.testing.expect(recovered.replayed);
    var invocation = try recovered.buildFxInvocation(
        "/path/to/fx",
        &.{},
        .recover_after_definitive_end,
    );
    defer invocation.deinit();
    try expectArgv(&.{
        "/path/to/fx",
        "--state-dir",
        root,
        "--name",
        "Native supervisor fixture",
    }, invocation.argv);
    try std.testing.expectEqualStrings(
        initial_id,
        invocation.environment.get(child_runtime.conversation_id_env).?,
    );
}

test "native prepared-fresh recovery resumes the durable active Conversation" {
    const alloc = std.testing.allocator;
    try installLauncherTestEnviron();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var digest: [64]u8 = undefined;
    const request = try testRequest(root, "recovery-attempt", .fresh, &digest);
    {
        var initial = try PreparedLaunch.prepare(alloc, request);
        defer initial.deinit();
        var active = try initial.ledger.updateActiveConversation(
            request.admission_key,
            request.launch_digest,
            request.launch_id,
            "conversation-after-new",
        );
        active.deinit();
    }
    try createTestDurableConversation(alloc, root, "conversation-after-new");

    var recovered = try PreparedLaunch.prepare(alloc, request);
    defer recovered.deinit();
    try std.testing.expect(recovered.replayed);
    var invocation = try recovered.buildFxInvocation(
        "/path/to/fx",
        &.{},
        .recover_after_definitive_end,
    );
    defer invocation.deinit();
    try std.testing.expectEqualStrings(
        "resume",
        invocation.argv[invocation.argv.len - 2],
    );
    try std.testing.expectEqualStrings(
        "conversation-after-new",
        invocation.argv[invocation.argv.len - 1],
    );
    try std.testing.expectEqualStrings(
        "conversation-after-new",
        invocation.environment.get(child_runtime.conversation_id_env).?,
    );
}

const TerminalOutcomeKind = enum {
    exited,
    signalled,
    exec_failed,
};

const TerminalOutcomeCase = struct {
    key: []const u8,
    script: ?[]const u8,
    kind: TerminalOutcomeKind,
};

const TerminalDurabilityFailureProbe = struct {
    fired: bool = false,

    fn syncFile(raw: ?*anyopaque, file: std.Io.File) anyerror!void {
        const self: *TerminalDurabilityFailureProbe = @ptrCast(@alignCast(raw.?));
        if (!self.fired) {
            self.fired = true;
            return error.InjectedTerminalDurabilityFailure;
        }
        try file.sync(io_mod.getIo());
    }

    fn ops(self: *TerminalDurabilityFailureProbe) io_mod.DurableOps {
        return .{ .ctx = self, .sync_file = syncFile };
    }
};

test "native supervisor retains exited signalled and exec-failed outcomes" {
    const alloc = std.testing.allocator;
    try installLauncherTestEnviron();
    inline for ([_]TerminalOutcomeCase{
        .{
            .key = "exit-attempt",
            .script = "exit 7",
            .kind = .exited,
        },
        .{ .key = "signal-attempt", .script = "kill -TERM $$", .kind = .signalled },
        .{ .key = "exec-attempt", .script = null, .kind = .exec_failed },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(root);
        var digest: [64]u8 = undefined;
        const request = try testRequest(root, case.key, .fresh, &digest);
        var prepared = try PreparedLaunch.prepare(alloc, request);
        defer prepared.deinit();

        const executable = if (case.script == null) "/definitely/missing/fx-child" else "/bin/sh";
        const extra: []const []const u8 = if (case.script) |script| &.{ "-c", script } else &.{};
        var environment = try io_mod.cloneEnvironMap(alloc);
        try child_runtime.applyChildEnvironment(
            &environment,
            prepared.accepted.record,
            prepared.accepted.record.initial_conversation_id,
        );
        var argv_storage = [_][]const u8{ executable, "", "" };
        var argv: []const []const u8 = argv_storage[0..1];
        if (extra.len > 0) {
            argv_storage[1] = extra[0];
            argv_storage[2] = extra[1];
            argv = &argv_storage;
        }
        var invocation = FxInvocation{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .environment = environment,
            .argv = argv,
            .cwd = root,
        };
        environment = undefined;
        defer invocation.deinit();
        var supervisor = try NativeSupervisor.spawn(&prepared, &invocation, .initial);
        supervisor.now_ms = launcherTestTimestampMs;
        var final = try supervisor.wait();
        defer final.deinit();
        const outcome = final.record.final_receipt.?.outcome;
        switch (case.kind) {
            .exited => try std.testing.expectEqual(@as(u8, 7), outcome.exited),
            .signalled => try std.testing.expect(outcome.signalled != 0),
            .exec_failed => try std.testing.expect(outcome.exec_failed.len > 0),
        }
    }
}

test "native supervisor retries final receipt persistence without reaping a second time" {
    const alloc = std.testing.allocator;
    try installLauncherTestEnviron();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var digest: [64]u8 = undefined;
    const request = try testRequest(root, "terminal-retry-attempt", .fresh, &digest);
    var prepared = try PreparedLaunch.prepare(alloc, request);
    defer prepared.deinit();

    var environment = try io_mod.cloneEnvironMap(alloc);
    try child_runtime.applyChildEnvironment(
        &environment,
        prepared.accepted.record,
        prepared.accepted.record.initial_conversation_id,
    );
    var invocation = FxInvocation{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .environment = environment,
        .argv = &.{ "/bin/sh", "-c", "exit 9" },
        .cwd = root,
    };
    environment = undefined;
    defer invocation.deinit();
    var supervisor = try NativeSupervisor.spawn(&prepared, &invocation, .initial);
    supervisor.now_ms = launcherTestTimestampMs;
    var failure = TerminalDurabilityFailureProbe{};
    prepared.ledger.options.durable_ops = failure.ops();
    try std.testing.expectError(
        error.DurableReplacePreRenameFailed,
        supervisor.wait(),
    );
    try std.testing.expect(failure.fired);
    try std.testing.expect(supervisor.child == null);
    try std.testing.expect(supervisor.pending_terminal != null);
    try std.testing.expect(!supervisor.terminal_recorded);
    var before_retry = try prepared.retained();
    defer before_retry.deinit();
    try std.testing.expect(before_retry.record.final_receipt == null);

    prepared.ledger.options.durable_ops = .{};
    var final = try supervisor.wait();
    defer final.deinit();
    try std.testing.expectEqual(@as(u8, 9), final.record.final_receipt.?.outcome.exited);
    try std.testing.expect(supervisor.pending_terminal == null);
    try std.testing.expect(supervisor.terminal_recorded);
}

test "native supervisor never starts a launch cancelled before its first Turn" {
    const alloc = std.testing.allocator;
    try installLauncherTestEnviron();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var digest: [64]u8 = undefined;
    const request = try testRequest(root, "cancelled-attempt", .fresh, &digest);
    var prepared = try PreparedLaunch.prepare(alloc, request);
    defer prepared.deinit();
    var cancelled = try prepared.cancel(.{
        .admission_key = request.admission_key,
        .launch_digest = request.launch_digest,
        .launch_id = request.launch_id,
        .request_id = "cancel-before-spawn",
    });
    cancelled.deinit();

    var invocation = try prepared.buildFxInvocation("/bin/sh", &.{}, .initial);
    defer invocation.deinit();
    try std.testing.expectError(
        error.LaunchCancelledBeforeStart,
        NativeSupervisor.spawn(&prepared, &invocation, .initial),
    );
    var retained = try prepared.retained();
    defer retained.deinit();
    try std.testing.expect(retained.record.final_receipt == null);
    try std.testing.expect(
        retained.record.decision.?.decision == .cancelled_before_start,
    );
}
