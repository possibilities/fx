// The downstream fork's local development gate imports only the modules that
// own carried behavior. Keeping this root separate from main.zig avoids
// compiling and discovering the complete native test graph for every edit.
test {
    _ = @import("acp/sessions.zig");
    _ = @import("acp/types.zig");
    _ = @import("acp/prompt.zig");
    _ = @import("builtins/hooks/ade_events.zig");
    _ = @import("builtins/hooks/ade_git_roots.zig");
    _ = @import("builtins/hooks/lifecycle_state.zig");
    _ = @import("core/agent/runtime/gateway_step.zig");
    _ = @import("core/app/app_entry_runtime.zig");
    _ = @import("core/app/app_input_runtime.zig");
    _ = @import("core/app/app_lifecycle.zig");
    _ = @import("core/app/app_profile_runtime.zig");
    _ = @import("core/app/app_runtime_setup.zig");
    _ = @import("core/app/app_session_runtime.zig");
    _ = @import("core/app/input_approval_runtime.zig");
    _ = @import("core/app/input_interrupt_runtime.zig");
    _ = @import("core/cli/cli_surface.zig");
    _ = @import("core/config/config_runtime.zig");
    _ = @import("core/auth/auth_runtime.zig");
    _ = @import("core/control/work_control.zig");
    _ = @import("core/hosts/native_external_editor.zig");
    _ = @import("core/inference/structured_receipt_ledger.zig");
    _ = @import("core/inference/structured_schema.zig");
    _ = @import("core/inference/structured_subscription.zig");
    _ = @import("core/inference/structured_subscription_cli.zig");
    _ = @import("core/mcp/mcp_runtime.zig");
    _ = @import("core/notifications/sound.zig");
    _ = @import("core/output/output_contracts.zig");
    _ = @import("core/session/session_naming.zig");
    _ = @import("core/skills/skill_runtime.zig");
    _ = @import("core/subagent/approval_registry.zig");
    _ = @import("core/tooling/tool_runtime.zig");
    _ = @import("core/tooling/tool_selection.zig");
    _ = @import("core/tooling/tool_admission.zig");
    _ = @import("core/slash_commands/command_specs.zig");
    _ = @import("gateway/responses_protocol.zig");
    _ = @import("tools/skills/skill_search.zig");
    _ = @import("napi_session_store.zig");
    _ = @import("ui/transcript/runtime.zig");
}
