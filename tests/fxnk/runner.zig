const builtin = @import("builtin");
const std = @import("std");

const expected_names = [_][]const u8{
    "builtins.hooks.ade_events.test.ADE feed serializes a main turn as one versioned JSON line",
    "builtins.hooks.ade_git_roots.test.ADE Git roots retain first discovery order and checkpoint without a socket",
    "core.tooling.tool_runtime.test.ADE edited path reporting requires successful committed mutation results",
    "core.tooling.tool_runtime.test.ADE terminal mutation completion requires exit-zero proof for durable starts",
    "core.tooling.tool_runtime.test.ADE durable terminal start classifies the declared working directory",
    "core.tooling.tool_runtime.test.ADE terminal root tracking follows only filesystem-write classification",
    "core.agent.runtime.gateway_step.test.provider-local immediate usage bypasses durable Gateway observations",
    "core.app.app_input_runtime.test.app_input_runtime ctrl+t invokes upgrade shortcut without composer mutation",
    "core.app.app_input_runtime.test.app_input_runtime ctrl+g invokes external editor without composer mutation",
    "core.app.app_lifecycle.test.loadStartupState lets FX_EFFORT win over the configured effort without rewriting it",
    "core.cli.cli_surface.test.global system prompt file modifiers preserve replacement and append order",
    "core.cli.cli_surface.test.ACP command routes parsed options and launch config through the injected runner",
    "core.hosts.native_external_editor.test.external editor returns valid text and treats nonzero exit as cancellation",
    "core.output.output_contracts.test.model list JSON preserves ordered reasoning efforts per provider model",
    "core.session.session_naming.test.generated titles slug to lowercase hyphens, bounded and re-trimmed",
    "core.session.session_naming.test.a settled first line freezes the title and lets the stream finish",
    "core.session.session_naming.test.a stream without a line break freezes the title at the capture bound",
    "core.skills.skill_runtime.test.invocation root authority stays fixed after the selected path is rebound",
    "ui.transcript.runtime.test.pending resume projection accepts candidate row below base content through recovery",
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
