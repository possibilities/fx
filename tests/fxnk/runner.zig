const builtin = @import("builtin");
const std = @import("std");

const expected_names = [_][]const u8{
    "acp.sessions.test.ACP restore rejects MCP servers when host capability is disabled",
    "builtins.hooks.ade_events.test.ADE feed serializes a main turn as one versioned JSON line",
    "builtins.hooks.ade_events.test.ADE feed serializes native session metadata as a generic raw event",
    "builtins.hooks.ade_events.test.ADE feed serializes an additive Git root discovery record",
    "builtins.hooks.ade_git_roots.test.ADE Git roots retain first discovery order and checkpoint without a socket",
    "builtins.hooks.ade_events.test.ADE feed resolves subagent attention with the child's own working snapshot",
    "builtins.hooks.ade_events.test.ADE feed carries each agent's own snapshot rather than the main agent's",
    "builtins.hooks.ade_events.test.ADE sequence advances through record_too_large and queue_full drops",
    "builtins.hooks.ade_events.test.ADE feed refuses tool arguments that would break record framing",
    "builtins.hooks.ade_events.test.ADE child records keep their captured parent across a main session change",
    "core.subagent.tool_host.test.relationship approval publishes its resolution before the child is released",
    "core.app.input_approval_runtime.test.production approval bridge keeps exact identity and first winner across both surfaces",
    "core.app.input_approval_runtime.test.two real pending approvals keep exact identity while each surface wins once",
    "builtins.hooks.lifecycle_state.test.lifecycle reducer carries attention through resolution and turn end",
    "builtins.hooks.lifecycle_state.test.lifecycle reducer ignores unmatched attention resolution",
    "builtins.hooks.lifecycle_state.test.lifecycle reducer keeps main and subagent states independent",
    "builtins.hooks.lifecycle_state.test.lifecycle reducer pairs a non-null attention kind only with blocked",
    "core.agent.worker_runtime.test.work control snapshot and text update preserve native admission order",
    "core.agent.worker_runtime.test.work control snapshot and update enforce semantic bounds",
    "core.control.work_control.test.strict authenticated request decoding preserves opaque turn ids",
    "core.control.work_control.test.request decoding rejects partial authority and extra parameters",
    "core.control.work_control.test.success responses carry correlated authoritative snapshots",
    "core.app.input_interrupt_runtime.test.hidden interrupt pauses queued work without opening the human editor",
    "core.tooling.tool_runtime.test.ADE edited path reporting requires successful committed mutation results",
    "core.tooling.tool_runtime.test.ADE terminal mutation completion requires exit-zero proof for durable starts",
    "core.tooling.tool_runtime.test.ADE durable terminal start classifies the declared working directory",
    "core.tooling.tool_runtime.test.ADE terminal root tracking follows only filesystem-write classification",
    "core.agent.runtime.gateway_step.test.provider-local exact usage reaches session accounting",
    "core.app.app_input_runtime.test.app_input_runtime ctrl+t invokes upgrade shortcut without composer mutation",
    "core.app.app_input_runtime.test.app_input_runtime ctrl+g invokes external editor without composer mutation",
    "core.app.app_input_runtime.test.agent and MCP question cancellation resolve accepted question attention",
    "core.app.app_input_runtime.test.late question cancellations do not resolve attention",
    "core.app.app_session_runtime.test.persistence in-place initialization preserves empty ownership",
    "core.auth.auth_runtime.test.auth in-place initialization preserves empty runtime state",
    "core.app.app_lifecycle.test.loadStartupState lets FX_EFFORT win over the configured effort without rewriting it",
    "core.cli.cli_surface.test.global system prompt file modifiers preserve replacement and append order",
    "core.cli.cli_surface.test.state system prompts compose replacement append conflict and explicit precedence",
    "core.cli.cli_surface.test.ACP command routes parsed options and launch config through the injected runner",
    "core.app.app_entry_runtime.test.app entry preserves every launch control across an upgrade relaunch",
    "core.app.app_entry_runtime.test.upgrade relaunch recovery shell-quotes unsafe arguments",
    "core.cli.cli_surface.test.global prompt detection scans across shared TUI and ACP controls",
    "core.cli.cli_surface.test.interactive unknown native tool selection renders missing_native_tool before launch teardown",
    "acp.server.test.ACP child authority preserves native-tool suppression and allowlisting",
    "core.app.app_runtime_setup.test.loadSkills discovers ordered invocation roots when HOME is missing",
    "core.app.app_profile_runtime.test.TUI profile helpers read and mutate only the selected state root",
    "core.mcp.mcp_runtime.test.unapproved workspace logout deletes only selected profile credentials",
    "core.app.app_commands.test.state-isolated usage dashboard refresh never reads ambient home",
    "core.config.config_runtime.test.launch permission policy owns a canonical path and parsed rule order",
    "core.hosts.native_external_editor.test.external editor returns valid text and treats nonzero exit as cancellation",
    "core.notifications.sound.test.macOS attention keeps one sound in flight while emitting every terminal bell",
    "core.notifications.sound.test.detached waiter owns sound state beyond player teardown",
    "core.output.output_contracts.test.model list JSON preserves ordered reasoning efforts per provider model",
    "core.session.session_naming.test.generated titles slug to lowercase hyphens, bounded and re-trimmed",
    "core.session.session_naming.test.a settled first line freezes the title and lets the stream finish",
    "core.session.session_naming.test.a stream without a line break freezes the title at the capture bound",
    "core.skills.skill_runtime.test.invocation root authority stays fixed after the selected path is rebound",
    "tools.skills.skill_search.test.skill search includes invocation-only roots",
    "core.tooling.tool_runtime.test.skill tool preserves exclusive invocation roots",
    "napi_session_store.test.N-API Codex session bridge exchanges requests and keeps stale operations inert",
    "core.auth.auth_runtime.test.pinned ChatGPT account rejects a swapped host session before refresh side effects",
    "ui.transcript.runtime.test.pending resume projection accepts candidate row below base content through recovery",
    "core.app.app_session_naming_runtime.test.pending launch name transfers ownership once and clears without leakage",
    "core.app.app_session_runtime.test.startup picker cancellation retains launch name until persistence and a fresh session cannot inherit it",
    "core.app.app_session_runtime.test.interactive session resume uses the live transition and shared restore path",
    "core.app.app_session_runtime.test.launch name applies to the exact resumed target after new and does not leak",
    "core.app.app_session_runtime.test.validateSessionTitle accepts printable text and rejects malformed input",
    "core.app.app_session_runtime.test.renameActiveSession persists the title to the sidecar and session index",
    "core.app.app_session_runtime.test.fallback generated and manual titles share one durable metadata path",
    "core.cli.cli_surface.test.global launch name parsing owns one normalized optional title",
    "core.cli.cli_surface.test.global launch name parsing rejects duplicate missing and invalid values",
    "core.cli.cli_surface.test.launch name is restricted to interactive and resume commands",
    "core.session.session_display_metadata.test.session display metadata validates explicit titles at the shared native boundary",
    "core.slash_commands.command_specs.test.rendered top-level help is a complete CLI navigation page",
    "core.slash_commands.command_specs.test.top-level help renders flags as compact aligned rows",
    "core.slash_commands.command_specs.test.default top-level help styles fit the startup buffer",
    "core.control.launch_admission_final.test.launch admission final timestamp formatter emits strict UTC milliseconds",
    "core.control.launch_admission_final.test.launch admission final strict golden codec matches frozen schema v1 fixture",
    "core.control.launch_admission_final.test.launch admission final strict codec rejects noncanonical and malformed boundaries",
    "core.control.launch_admission_final.test.launch admission final digest helpers reproduce frozen launch and receipt authorities",
    "core.control.launch_admission_final_ledger.test.launch ledger pre-rename failures leave every durable boundary retryable",
    "core.control.launch_admission_final_ledger.test.launch ledger post-rename indeterminate failures recover every durable boundary",
    "core.control.launch_admission_final_ledger.test.launch ledger retries a matching digest with the current request identity",
    "core.control.launch_admission_final_ledger.test.launch ledger cancellation wins before admission and remains permanent",
    "core.control.launch_admission_final_ledger.test.launch ledger admission wins before cancellation and replays the original Turn",
    "core.control.launch_admission_final_ledger.test.launch ledger rejects conflicting digest and recovers a lost response",
    "core.control.launch_admission_final_ledger.test.launch ledger preserves active Conversation and every terminal outcome until exact ack",
    "core.control.launch_admission_final_ledger.test.launch ledger exact resume requires and retains the requested Conversation identity",
    "core.control.launch_admission_final_runtime.test.launch child runtime consumes a fresh Conversation reservation once and publishes active identity",
    "core.control.launch_admission_final_runtime.test.launch child runtime requires fresh reservation or the exact active Conversation",
    "core.control.launch_admission_final_runtime.test.launch child runtime durably decides the first Work-control prompt and replays its Turn",
    "core.control.launch_admission_final_launcher.test.native launch preparation reserves fresh identity and exact resume before exec",
    "core.control.launch_admission_final_launcher.test.native prepared-fresh recovery reuses its reservation before any durable Conversation exists",
    "core.control.launch_admission_final_launcher.test.native prepared-fresh recovery resumes the durable active Conversation",
    "core.control.launch_admission_final_launcher.test.native supervisor retains exited signalled and exec-failed outcomes",
    "core.control.launch_admission_final_launcher.test.native supervisor retries final receipt persistence without reaping a second time",
    "core.control.launch_admission_final_launcher.test.native supervisor never starts a launch cancelled before its first Turn",
    "core.control.launch_provider.test.private launch provider prepares builds inspects and records external final receipts",
    "core.control.launch_provider.test.private launch provider rejects wrong auth unknown fields and conflicting correlation",
    "core.control.launch_provider.test.private launch provider endpoint directory is exact user-owned mode 0700",
    "core.agent.worker_runtime.test.durable initial Work-control admission reserves capacity before decision and publishes exact Turn",
    "core.agent.worker_runtime.test.durable initial Work-control cancellation is permanent and exact admitted retries never enqueue twice",
    "core.agent.worker_runtime.test.durable initial Work-control recovery reuses an already-present Turn",
    "core.app.app_session_runtime.test.launch-correlated fresh session consumes its reservation once and publishes every active Conversation",
    "core.app.app_session_runtime.test.launch-correlated exact resume publishes the restored active Conversation",
    "core.inference.structured_schema.test.structured subscription object schema validator enforces the local strict subset",
    "core.inference.structured_schema.test.structured subscription schema compares JSON numbers without integer precision loss",
    "core.inference.structured_schema.test.structured subscription schema rejects untyped keywords and bounds evaluation",
    "core.inference.structured_receipt_ledger.test.structured inference receipt ledger persists phases terminal replay and acknowledgement",
    "core.inference.structured_subscription.test.structured subscription inference enforces catalog order and exact tool-free request",
    "core.inference.structured_subscription.test.structured subscription inference replays terminals rejects conflicts and acknowledges idempotently",
    "core.inference.structured_subscription.test.structured subscription inference durably classifies refusal schema and provider failures",
    "core.inference.structured_subscription.test.structured subscription inference cancellation is durable before admission and provider terminal wins after admission",
    "core.inference.structured_subscription.test.structured subscription inference recovers admitted request without a second provider call",
    "core.inference.structured_subscription.test.structured subscription inference bounds provider identifiers and terminal persistence",
    "core.inference.structured_subscription_cli.test.structured subscription CLI accepts one strict versioned inference frame",
    "core.inference.structured_subscription_cli.test.structured subscription CLI rejects multiple missing-newline and oversized frames",
    "gateway.responses_protocol.test.Responses reducer classifies refusal content as content filter",
    "gateway.responses_protocol.test.Responses reducer preserves a terminal provider outcome after late cancellation",
    "gateway.responses_protocol.test.Responses reducer honors an already-read terminal event over cancellation",
};

fn isExpected(name: []const u8) bool {
    for (expected_names) |expected| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}

fn validateInventory() bool {
    var valid = true;
    for (expected_names) |expected| {
        var matches: usize = 0;
        for (builtin.test_functions) |test_fn| {
            matches += @intFromBool(std.mem.eql(u8, test_fn.name, expected));
        }
        if (matches != 1) {
            std.debug.print("FXNK-CANARIES expected exactly one '{s}', found {d}\n", .{ expected, matches });
            valid = false;
        }
    }
    for (builtin.test_functions) |test_fn| {
        if (std.mem.endsWith(u8, test_fn.name, ".test_0")) continue;
        if (!isExpected(test_fn.name)) {
            std.debug.print("FXNK-CANARIES rejected unexpected selected test '{s}'\n", .{test_fn.name});
            valid = false;
        }
    }
    return valid;
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    if (!validateInventory()) std.process.exit(1);

    var passed: usize = 0;
    var failed: usize = 0;
    for (builtin.test_functions) |test_fn| {
        if (!isExpected(test_fn.name)) continue;

        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        std.testing.log_level = .warn;
        std.testing.environ = init.environ;

        std.debug.print("FXNK-CANARY {s}...", .{test_fn.name});
        if (test_fn.func()) |_| {
            passed += 1;
            std.debug.print("PASS\n", .{});
        } else |err| {
            failed += 1;
            std.debug.print("FAIL ({t})\n", .{err});
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        }

        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() == .leak) {
            failed += 1;
            std.debug.print("FXNK-CANARY {s}...LEAK\n", .{test_fn.name});
        }
    }

    std.debug.print("FXNK-CANARIES {d}/{d} passed\n", .{ passed, expected_names.len });
    if (failed != 0 or passed != expected_names.len) std.process.exit(1);
}
