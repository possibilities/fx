const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");

const Allocator = std.mem.Allocator;
pub const LoadSkillsError = Allocator.Error;

pub const LoadedSkills = struct {
    dir: []u8 = &.{},
    skills: []skill_runtime.Skill = &.{},
    diagnostics: []skill_runtime.SkillDiagnostic = &.{},

    pub fn deinit(self: *LoadedSkills, alloc: Allocator) void {
        if (self.dir.len > 0) alloc.free(self.dir);
        skill_runtime.freeSkills(alloc, self.skills);
        skill_runtime.freeSkillDiagnostics(alloc, self.diagnostics);
        self.* = .{};
    }
};

pub fn loadSkills(
    alloc: Allocator,
    workspace_root: []const u8,
    invocation_skill_roots: []const []const u8,
    root_policy: skill_contract.RootPolicy,
) LoadSkillsError!LoadedSkills {
    const configured_home = io_mod.getenv("HOME");
    const selected_home = configured_home orelse return .{};
    return loadSkillsFromHomes(
        alloc,
        workspace_root,
        configured_home,
        selected_home,
        invocation_skill_roots,
        root_policy,
    );
}

pub fn loadSkillsFromHome(
    alloc: Allocator,
    workspace_root: []const u8,
    configured_home: []const u8,
    invocation_skill_roots: []const []const u8,
    root_policy: skill_contract.RootPolicy,
) LoadSkillsError!LoadedSkills {
    return loadSkillsFromHomes(
        alloc,
        workspace_root,
        io_mod.getenv("HOME"),
        configured_home,
        invocation_skill_roots,
        root_policy,
    );
}

fn loadSkillsFromHomes(
    alloc: Allocator,
    workspace_root: []const u8,
    workspace_home: ?[]const u8,
    configured_home: []const u8,
    invocation_skill_roots: []const []const u8,
    root_policy: skill_contract.RootPolicy,
) LoadSkillsError!LoadedSkills {
    const canonical_home = io_mod.realpathAlloc(alloc, configured_home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (canonical_home) |home| alloc.free(home);
    const home = canonical_home orelse configured_home;
    const canonical_workspace_home = if (workspace_home) |value|
        io_mod.realpathAlloc(alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        }
    else
        null;
    defer if (canonical_workspace_home) |value| alloc.free(value);
    const workspace_home_root = canonical_workspace_home orelse workspace_home;
    const dir = try profile_paths.managedSkillsDir(alloc, home);
    errdefer alloc.free(dir);
    const discovery = try skill_runtime.loadVisibleSkillsWithHomes(
        alloc,
        workspace_root,
        workspace_home_root,
        home,
        dir,
        invocation_skill_roots,
        root_policy,
    );

    return .{
        .dir = dir,
        .skills = discovery.skills,
        .diagnostics = discovery.diagnostics,
    };
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const TestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: ?[]const u8) !*TestHome {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestHome) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn tmpPath(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, dir, sub_path);
}

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

const test_root_policy: skill_contract.RootPolicy = .{
    .managed_root_source = .global_fx,
};

const test_split_home_root_policy: skill_contract.RootPolicy = .{
    .workspace_roots = &.{.{ .source = .workspace_codex, .path = ".codex/skills" }},
    .managed_root_source = .global_fx,
    .global_roots = &.{.{ .source = .global_codex, .path = ".codex/skills" }},
};

test "loadSkills returns empty defaults when HOME is missing" {
    const alloc = std.testing.allocator;
    const home = try TestHome.install(alloc, null);
    defer home.deinit();

    var loaded = try loadSkills(alloc, "/tmp/workspace", &.{}, test_root_policy);
    defer loaded.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), loaded.dir.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.skills.len);
}

test "loadSkills discovers ordered invocation roots when HOME is missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "first/review/SKILL.md",
        \\---
        \\name: review
        \\description: First invocation skill
        \\---
        \\Review carefully.
    );
    try writeTempFile(&tmp, "second/release/SKILL.md",
        \\---
        \\name: release
        \\description: Second invocation skill
        \\---
        \\Prepare a release.
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const first = try tmpPath(alloc, tmp.dir, "first");
    defer alloc.free(first);
    const second = try tmpPath(alloc, tmp.dir, "second");
    defer alloc.free(second);
    const workspace = try tmpPath(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const roots = [_][]const u8{ first, second };

    const home = try TestHome.install(alloc, null);
    defer home.deinit();

    var loaded = try loadSkills(alloc, workspace, &roots, test_root_policy);
    defer loaded.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), loaded.dir.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.skills.len);
    try std.testing.expectEqualStrings("review", loaded.skills[0].name);
    try std.testing.expectEqualStrings("release", loaded.skills[1].name);
    try std.testing.expectEqual(skill_runtime.SkillSource.invocation, loaded.skills[0].source);
    try std.testing.expectEqual(skill_runtime.SkillSource.invocation, loaded.skills[1].source);
    try std.testing.expectEqualStrings(first, loaded.skills[0].read_authority.?);
    try std.testing.expectEqualStrings(second, loaded.skills[1].read_authority.?);
}

test "loadSkills loads managed skills under HOME" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/.fx/skills/demo/SKILL.md",
        \\---
        \\name: demo
        \\description: Demo skill
        \\---
        \\Use this for tests.
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");

    const home_path = try tmpPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const workspace_path = try tmpPath(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_path);

    const home = try TestHome.install(alloc, home_path);
    defer home.deinit();

    var loaded = try loadSkills(alloc, workspace_path, &.{}, test_root_policy);
    defer loaded.deinit(alloc);

    const expected_dir = try profile_paths.managedSkillsDir(alloc, home_path);
    defer alloc.free(expected_dir);

    try std.testing.expectEqualStrings(expected_dir, loaded.dir);
    try std.testing.expectEqual(@as(usize, 1), loaded.skills.len);
    try std.testing.expectEqualStrings("demo", loaded.skills[0].name);
    try std.testing.expectEqualStrings("Demo skill", loaded.skills[0].description);
    try std.testing.expectEqual(skill_runtime.SkillSource.global_fx, loaded.skills[0].source);
    try std.testing.expectEqual(@as(usize, 0), loaded.diagnostics.len);
}

test "selected skill profile preserves workspace roots without ambient global roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "ambient/workspace/.codex/skills/workspace-skill/SKILL.md",
        \\---
        \\name: workspace-skill
        \\description: Workspace skill
        \\---
        \\workspace
    );
    try writeTempFile(&tmp, "ambient/.codex/skills/ambient-global/SKILL.md",
        \\---
        \\name: ambient-global
        \\description: Ambient global skill
        \\---
        \\ambient
    );
    try writeTempFile(&tmp, "selected/.codex/skills/selected-global/SKILL.md",
        \\---
        \\name: selected-global
        \\description: Selected global skill
        \\---
        \\selected
    );
    try writeTempFile(&tmp, "selected/.fx/skills/managed/SKILL.md",
        \\---
        \\name: managed
        \\description: Managed skill
        \\---
        \\managed
    );

    const ambient_home = try tmpPath(alloc, tmp.dir, "ambient");
    defer alloc.free(ambient_home);
    const selected_home = try tmpPath(alloc, tmp.dir, "selected");
    defer alloc.free(selected_home);
    const workspace = try tmpPath(alloc, tmp.dir, "ambient/workspace");
    defer alloc.free(workspace);

    const home = try TestHome.install(alloc, ambient_home);
    defer home.deinit();

    var loaded = try loadSkillsFromHome(
        alloc,
        workspace,
        selected_home,
        test_split_home_root_policy,
    );
    defer loaded.deinit(alloc);

    var found_workspace = false;
    var found_selected = false;
    var found_managed = false;
    var found_ambient = false;
    for (loaded.skills) |skill| {
        if (std.mem.eql(u8, skill.name, "workspace-skill")) found_workspace = true;
        if (std.mem.eql(u8, skill.name, "selected-global")) found_selected = true;
        if (std.mem.eql(u8, skill.name, "managed")) found_managed = true;
        if (std.mem.eql(u8, skill.name, "ambient-global")) found_ambient = true;
    }
    try std.testing.expect(found_workspace);
    try std.testing.expect(found_selected);
    try std.testing.expect(found_managed);
    try std.testing.expect(!found_ambient);
}

test "loadSkills canonicalizes a symlinked HOME before discovering optional roots" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "real-home/workspace");
    tmp.dir.symLink(std.testing.io, "real-home", "linked-home", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };
    const tmp_root = try tmpPath(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const linked_home = try std.fs.path.join(alloc, &.{ tmp_root, "linked-home" });
    defer alloc.free(linked_home);
    const workspace_path = try tmpPath(alloc, tmp.dir, "real-home/workspace");
    defer alloc.free(workspace_path);

    const home = try TestHome.install(alloc, linked_home);
    defer home.deinit();

    var loaded = try loadSkills(alloc, workspace_path, &.{}, test_root_policy);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.skills.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.diagnostics.len);
}

test "loadSkills propagates allocation failure instead of returning an empty inventory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");

    const home_path = try tmpPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const workspace_path = try tmpPath(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_path);
    const home = try TestHome.install(alloc, home_path);
    defer home.deinit();

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        loadSkills(failing.allocator(), workspace_path, &.{}, test_root_policy),
    );
}
