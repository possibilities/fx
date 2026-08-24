const ade_events = @import("builtins/hooks/ade_events.zig");
const ade_git_roots = @import("builtins/hooks/ade_git_roots.zig");

test "ADE focused imports" {
    _ = ade_events;
    _ = ade_git_roots;
}
