const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub fn explicitHome(app: anytype) ?[]const u8 {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "profile_home")) return app.profile_home;
    return null;
}

pub fn home(app: anytype) ?[]const u8 {
    return explicitHome(app) orelse io_mod.getenv("HOME");
}

pub fn attemptUserPreferences(
    app: anytype,
    patch: config_runtime.UserSettingsPatch,
) config_runtime.CommitAttempt {
    if (explicitHome(app)) |profile_home| {
        return config_runtime.attemptUserPreferencesFromHome(
            app.alloc,
            profile_home,
            patch,
        );
    }
    return config_runtime.attemptUserPreferences(app.alloc, patch);
}

pub fn loadMergedSettings(app: anytype) !config_runtime.Settings {
    if (explicitHome(app)) |profile_home| {
        return config_runtime.loadMergedSettingsFromHome(
            app.alloc,
            profile_home,
            app.workspace_root,
        );
    }
    return config_runtime.loadMergedSettings(app.alloc, app.workspace_root);
}

pub fn loadMergedSettingsDetailed(app: anytype) !config_runtime.DetailedSettings {
    if (explicitHome(app)) |profile_home| {
        return config_runtime.loadMergedSettingsDetailedFromHome(
            app.alloc,
            profile_home,
            app.workspace_root,
        );
    }
    return config_runtime.loadMergedSettingsDetailed(app.alloc, app.workspace_root);
}

pub fn addPermissionRule(
    app: anytype,
    scope: config_runtime.PermissionScope,
    workspace_root: ?[]const u8,
    category: []const u8,
    pattern: []const u8,
    action: types.PermissionAction,
) !config_runtime.CommitOutcome {
    if (explicitHome(app)) |profile_home| {
        return config_runtime.addPermissionRuleFromHome(
            app.alloc,
            profile_home,
            scope,
            workspace_root,
            category,
            pattern,
            action,
        );
    }
    return config_runtime.addPermissionRule(
        app.alloc,
        scope,
        workspace_root,
        category,
        pattern,
        action,
    );
}

pub fn removePermissionRule(
    app: anytype,
    scope: config_runtime.PermissionScope,
    workspace_root: ?[]const u8,
    category: []const u8,
    pattern: []const u8,
) !config_runtime.CommitOutcome {
    if (explicitHome(app)) |profile_home| {
        return config_runtime.removePermissionRuleFromHome(
            app.alloc,
            profile_home,
            scope,
            workspace_root,
            category,
            pattern,
        );
    }
    return config_runtime.removePermissionRule(
        app.alloc,
        scope,
        workspace_root,
        category,
        pattern,
    );
}

pub fn removeAllowlistRules(
    app: anytype,
    permission_scope: config_runtime.PermissionScope,
    workspace_root: ?[]const u8,
    reset_scope: config_runtime.AllowlistResetScope,
) !config_runtime.CommitOutcome {
    if (explicitHome(app)) |profile_home| {
        return config_runtime.removeAllowlistRulesFromHome(
            app.alloc,
            profile_home,
            permission_scope,
            workspace_root,
            reset_scope,
        );
    }
    return config_runtime.removeAllowlistRules(
        app.alloc,
        permission_scope,
        workspace_root,
        reset_scope,
    );
}

test "TUI profile helpers read and mutate only the selected state root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "state-a/.fx");
    try tmp.dir.createDirPath(std.testing.io, "state-b/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    {
        var file = try tmp.dir.createFile(std.testing.io, "state-a/.fx/settings.json", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{\"fast_mode\":false}\n");
    }
    {
        var file = try tmp.dir.createFile(std.testing.io, "state-b/.fx/settings.json", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{\"fast_mode\":false}\n");
    }
    const state_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "state-a");
    defer alloc.free(state_a);
    const state_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "state-b");
    defer alloc.free(state_b);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const TestApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8,
        profile_home: ?[]const u8,
    };
    var app = TestApp{
        .alloc = alloc,
        .workspace_root = workspace,
        .profile_home = state_a,
    };

    var before = try loadMergedSettings(&app);
    defer before.deinit(alloc);
    try std.testing.expectEqual(false, before.fast_mode.?);

    var attempt = attemptUserPreferences(&app, .{ .fast_mode = true });
    defer attempt.deinit(alloc);
    switch (attempt) {
        .outcome => {},
        .failure => |failure| return failure.err,
    }

    var selected = try loadMergedSettings(&app);
    defer selected.deinit(alloc);
    try std.testing.expectEqual(true, selected.fast_mode.?);
    var other = try config_runtime.loadMergedSettingsFromHome(
        alloc,
        state_b,
        workspace,
    );
    defer other.deinit(alloc);
    try std.testing.expectEqual(false, other.fast_mode.?);

    var permission_outcome = try addPermissionRule(
        &app,
        .user,
        null,
        "bash",
        "git status",
        .allow,
    );
    defer permission_outcome.deinit(alloc);
    var selected_after_rule = try loadMergedSettings(&app);
    defer selected_after_rule.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), selected_after_rule.permission_rules.rules.len);
    var other_after_rule = try config_runtime.loadMergedSettingsFromHome(
        alloc,
        state_b,
        workspace,
    );
    defer other_after_rule.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), other_after_rule.permission_rules.rules.len);
}
