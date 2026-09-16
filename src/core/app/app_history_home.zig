//! Resolves the root that owns a launch's history: sessions, prompt history,
//! and usage. Shape, identity, and history are chosen independently, so this is
//! deliberately not the profile home a shape or a credential came from. When no
//! history root is selected the profile home owns history, which keeps
//! `--state-dir` isolating all three exactly as it always has.
const std = @import("std");

/// The history root for an app, or null when history follows the ambient home.
pub fn forApp(app: anytype) ?[]const u8 {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "history_home")) {
        if (app.history_home) |home| return home;
    }
    if (comptime @hasField(App, "profile_home")) return app.profile_home;
    return null;
}

/// The history root for one launch's selections, resolved the same way.
pub fn forSelection(history_home: ?[]const u8, profile_home: ?[]const u8) ?[]const u8 {
    return history_home orelse profile_home;
}

test "an explicit history root wins and otherwise the profile home owns history" {
    try std.testing.expectEqualStrings(
        "/history",
        forSelection("/history", "/profile").?,
    );
    try std.testing.expectEqualStrings("/profile", forSelection(null, "/profile").?);
    try std.testing.expectEqualStrings("/history", forSelection("/history", null).?);
    try std.testing.expect(forSelection(null, null) == null);

    const Ambient = struct { profile_home: ?[]const u8 = null };
    var ambient = Ambient{};
    try std.testing.expect(forApp(&ambient) == null);

    const Selected = struct {
        profile_home: ?[]const u8 = "/profile",
        history_home: ?[]const u8 = "/history",
    };
    var selected = Selected{};
    try std.testing.expectEqualStrings("/history", forApp(&selected).?);
    selected.history_home = null;
    try std.testing.expectEqualStrings("/profile", forApp(&selected).?);
}
