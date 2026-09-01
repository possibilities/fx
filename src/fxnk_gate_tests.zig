// The downstream fork's local development gate imports only the modules that
// own carried behavior. Keeping this root separate from main.zig avoids
// compiling and discovering the complete native test graph for every edit.
test {
    _ = @import("acp/sessions.zig");
    _ = @import("builtins/hooks/ade_events.zig");
    _ = @import("builtins/hooks/ade_git_roots.zig");
    _ = @import("builtins/hooks/lifecycle_state.zig");
    _ = @import("core/agent/runtime/gateway_step.zig");
    _ = @import("core/app/app_entry_runtime.zig");
    _ = @import("core/app/app_bootstrap_runtime.zig");
    _ = @import("core/app/app_input_runtime.zig");
    _ = @import("core/app/app_lifecycle.zig");
    _ = @import("core/app/app_profile_runtime.zig");
    _ = @import("core/app/app_runtime_setup.zig");
    _ = @import("core/app/app_session_runtime.zig");
    _ = @import("core/app/input_approval_runtime.zig");
    _ = @import("core/cli/cli_surface.zig");
    _ = @import("core/config/config_runtime.zig");
    _ = @import("core/auth/auth_runtime.zig");
    _ = @import("core/control/work_control.zig");
    _ = @import("core/hosts/native_external_editor.zig");
    _ = @import("core/mcp/mcp_runtime.zig");
    _ = @import("core/notifications/sound.zig");
    _ = @import("core/output/output_contracts.zig");
    _ = @import("core/session/session_naming.zig");
    _ = @import("core/skills/skill_runtime.zig");
    _ = @import("core/subagent/tool_host.zig");
    _ = @import("core/tooling/tool_runtime.zig");
    _ = @import("tools/skills/skill_search.zig");
    _ = @import("napi_session_store.zig");
    _ = @import("ui/transcript/runtime.zig");
    _ = @import("core/app/app_session_naming_runtime.zig");
    _ = @import("core/session/session_display_metadata.zig");
    _ = @import("core/slash_commands/command_specs.zig");
    _ = @import("core/control/launch_admission_final.zig");
    _ = @import("core/control/launch_admission_final_ledger.zig");
    _ = @import("core/control/launch_admission_final_runtime.zig");
    _ = @import("core/control/launch_admission_final_launcher.zig");
    _ = @import("core/control/launch_provider.zig");
    _ = @import("structured_inference_test_root.zig");
}
