const app_agent_runtime = @import("core/app/app_agent_runtime.zig");
const ade_events = @import("builtins/hooks/ade_events.zig");
const ade_git_roots = @import("builtins/hooks/ade_git_roots.zig");

test "ADE focused imports" {
    _ = app_agent_runtime;
    _ = ade_events;
    _ = ade_git_roots;
}
