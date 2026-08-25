// The downstream fork's local development gate imports only the modules that
// own carried behavior. Keeping this root separate from main.zig avoids
// compiling and discovering the complete native test graph for every edit.
test {
    _ = @import("builtins/hooks/ade_events.zig");
    _ = @import("builtins/hooks/ade_git_roots.zig");
    _ = @import("core/agent/runtime/gateway_step.zig");
    _ = @import("core/app/app_input_runtime.zig");
    _ = @import("core/app/app_lifecycle.zig");
    _ = @import("core/cli/cli_surface.zig");
    _ = @import("core/hosts/native_external_editor.zig");
    _ = @import("core/output/output_contracts.zig");
    _ = @import("core/session/session_naming.zig");
    _ = @import("core/skills/skill_runtime.zig");
    _ = @import("ui/transcript/runtime.zig");
}
