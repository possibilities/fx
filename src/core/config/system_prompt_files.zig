const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const max_custom_bytes: usize = 256 * 1024;

pub const StateConventionResult = union(enum) {
    bypassed,
    absent,
    applied_replacement,
    applied_append,
    conflicting,
    failure: Failure,
};

pub const Request = struct {
    replacement_path: ?[]u8 = null,
    append_paths: [][]u8 = &.{},
    state_path: ?[]u8 = null,
    state_content: ?[]u8 = null,
    state_replaces_base: bool = false,

    pub fn deinit(self: *Request, alloc: Allocator) void {
        if (self.replacement_path) |path| alloc.free(path);
        for (self.append_paths) |path| alloc.free(path);
        if (self.append_paths.len > 0) alloc.free(self.append_paths);
        if (self.state_path) |path| alloc.free(path);
        if (self.state_content) |content| alloc.free(content);
        self.* = .{};
    }

    pub fn requested(self: Request) bool {
        return self.replacement_path != null or self.append_paths.len > 0 or self.state_content != null;
    }

    /// Duplicates only invocation-owned paths. Prepared state content is
    /// process-local and must be rediscovered from --state-dir on relaunch.
    pub fn cloneForPreparation(self: Request, alloc: Allocator) !Request {
        std.debug.assert(self.state_path == null and self.state_content == null);
        var result: Request = .{};
        errdefer result.deinit(alloc);
        if (self.replacement_path) |path| {
            result.replacement_path = try alloc.dupe(u8, path);
        }
        if (self.append_paths.len > 0) {
            const paths = try alloc.alloc([]u8, self.append_paths.len);
            var initialized: usize = 0;
            errdefer {
                for (paths[0..initialized]) |path| alloc.free(path);
                alloc.free(paths);
            }
            for (self.append_paths) |path| {
                paths[initialized] = try alloc.dupe(u8, path);
                initialized += 1;
            }
            result.append_paths = paths;
        }
        return result;
    }

    /// Adds the selected state root's conventional system prompt to this
    /// owned request. An explicit replacement is authoritative and bypasses
    /// discovery; an explicit append remains after the state-derived base.
    pub fn applyStateConvention(
        self: *Request,
        alloc: Allocator,
        state_home: []const u8,
    ) !StateConventionResult {
        if (self.replacement_path != null) return .bypassed;

        var profile_dir = (try openStateProfile(state_home)) orelse return .absent;
        defer profile_dir.close(io_mod.getIo());

        const presence = try inspectStateConvention(profile_dir);
        if (presence.replacement and presence.append) return .conflicting;
        const replaces_base = presence.replacement;
        const file_name = if (replaces_base)
            profile_paths.system_prompt_file_name
        else if (presence.append)
            profile_paths.system_prompt_append_file_name
        else
            return .absent;

        const path = if (replaces_base)
            try profile_paths.systemPromptPath(alloc, state_home)
        else
            try profile_paths.systemPromptAppendPath(alloc, state_home);
        self.state_path = path;
        const loaded = try loadOneFromDir(alloc, profile_dir, file_name, path, 0);
        switch (loaded) {
            .failure => |failure| return .{ .failure = failure },
            .content => |content| {
                errdefer alloc.free(content);
                const current_presence = try inspectStateConvention(profile_dir);
                if (current_presence.replacement != presence.replacement or
                    current_presence.append != presence.append)
                {
                    return error.StateConventionChanged;
                }
                self.state_content = content;
                self.state_replaces_base = replaces_base;
            },
        }

        return if (replaces_base) .applied_replacement else .applied_append;
    }

    pub fn compose(self: Request, alloc: Allocator, base: []const u8) !ComposeResult {
        var pieces: std.ArrayList([]u8) = .empty;
        defer {
            for (pieces.items) |piece| alloc.free(piece);
            pieces.deinit(alloc);
        }

        var custom_bytes: usize = if (self.state_content) |content| content.len else 0;
        if (self.replacement_path) |path| {
            const loaded = try loadOne(alloc, path, custom_bytes);
            switch (loaded) {
                .failure => |failure| return .{ .failure = failure },
                .content => |content| {
                    custom_bytes += content.len;
                    try appendOwnedPiece(&pieces, alloc, content);
                },
            }
        }
        for (self.append_paths) |path| {
            const loaded = try loadOne(alloc, path, custom_bytes);
            switch (loaded) {
                .failure => |failure| return .{ .failure = failure },
                .content => |content| {
                    custom_bytes += content.len;
                    try appendOwnedPiece(&pieces, alloc, content);
                },
            }
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const writer = &out.writer;
        if (self.replacement_path == null and !self.state_replaces_base) try writer.writeAll(base);
        if (self.state_content) |content| try writePiece(writer, content);
        for (pieces.items) |piece| {
            try writePiece(writer, piece);
        }
        return .{ .prompt = try out.toOwnedSlice() };
    }
};

pub const FailureReason = enum {
    unreadable,
    not_regular_file,
    too_large,
    invalid_text,
};

pub const Failure = struct {
    path: []const u8,
    reason: FailureReason,
};

pub const ComposeResult = union(enum) {
    prompt: []u8,
    failure: Failure,
};

const LoadResult = union(enum) {
    content: []u8,
    failure: Failure,
};

const StateConventionPresence = struct {
    replacement: bool = false,
    append: bool = false,
};

fn openStateProfile(state_home: []const u8) !?std.Io.Dir {
    const io = io_mod.getIo();
    var state_dir = try io_mod.openDirAbsoluteNoFollow(state_home, .{ .iterate = true });
    defer state_dir.close(io);

    var state_entries = state_dir.iterate();
    while (try state_entries.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, profile_paths.root_dir_name)) {
            return try state_dir.openDir(io, profile_paths.root_dir_name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
        }
    }
    return null;
}

fn inspectStateConvention(profile_dir: std.Io.Dir) !StateConventionPresence {
    const io = io_mod.getIo();
    var presence: StateConventionPresence = .{};
    var entries = profile_dir.iterate();
    while (try entries.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, profile_paths.system_prompt_file_name)) {
            presence.replacement = true;
        } else if (std.mem.eql(u8, entry.name, profile_paths.system_prompt_append_file_name)) {
            presence.append = true;
        }
        if (presence.replacement and presence.append) break;
    }
    return presence;
}

fn appendOwnedPiece(pieces: *std.ArrayList([]u8), alloc: Allocator, content: []u8) !void {
    pieces.append(alloc, content) catch |err| {
        alloc.free(content);
        return err;
    };
}

fn writePiece(writer: *std.Io.Writer, piece: []const u8) !void {
    if (writer.buffered().len > 0 and piece.len > 0) try writer.writeAll("\n\n");
    try writer.writeAll(piece);
}

fn loadOne(alloc: Allocator, path: []const u8, custom_bytes: usize) !LoadResult {
    return loadOneFromDir(alloc, std.Io.Dir.cwd(), path, path, custom_bytes);
}

fn loadOneFromDir(
    alloc: Allocator,
    dir: std.Io.Dir,
    sub_path: []const u8,
    display_path: []const u8,
    custom_bytes: usize,
) !LoadResult {
    if (custom_bytes > max_custom_bytes) return .{ .failure = .{ .path = display_path, .reason = .too_large } };

    // Inspect the path before opening it so a directory, device, or FIFO cannot
    // be treated as a prompt source (and, in particular, a FIFO cannot block
    // launch while waiting for a writer). Recheck the opened handle below: a
    // path may change between the two operations.
    const initial_stat = dir.statFile(io_mod.getIo(), sub_path, .{}) catch
        return .{ .failure = .{ .path = display_path, .reason = .unreadable } };
    if (initial_stat.kind != .file) return .{ .failure = .{ .path = display_path, .reason = .not_regular_file } };

    var file = io_mod.openExistingReadOnlyRegularFile(
        dir,
        sub_path,
        .follow,
    ) catch |err| switch (err) {
        error.DurablePathUnsafe => return .{ .failure = .{ .path = display_path, .reason = .not_regular_file } },
        else => return .{ .failure = .{ .path = display_path, .reason = .unreadable } },
    };
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch
        return .{ .failure = .{ .path = display_path, .reason = .unreadable } };
    if (stat.kind != .file) return .{ .failure = .{ .path = display_path, .reason = .not_regular_file } };

    const remaining = max_custom_bytes - custom_bytes;
    if (stat.size > remaining) return .{ .failure = .{ .path = display_path, .reason = .too_large } };
    const content = io_mod.readFileToEnd(alloc, &file, remaining + 1) catch |err| switch (err) {
        error.StreamTooLong => return .{ .failure = .{ .path = display_path, .reason = .too_large } },
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .{ .path = display_path, .reason = .unreadable } },
    };
    if (content.len > remaining) {
        alloc.free(content);
        return .{ .failure = .{ .path = display_path, .reason = .too_large } };
    }
    if (!text_utils.isModelSafeText(content)) {
        alloc.free(content);
        return .{ .failure = .{ .path = display_path, .reason = .invalid_text } };
    }
    return .{ .content = content };
}

fn writeFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    var file = try dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}

test "compose replaces the base and appends files in CLI order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "replacement", "replacement");
    try writeFile(tmp.dir, "first", "first");
    try writeFile(tmp.dir, "second", "second");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const replacement = try std.fs.path.join(alloc, &.{ root, "replacement" });
    defer alloc.free(replacement);
    const first = try std.fs.path.join(alloc, &.{ root, "first" });
    defer alloc.free(first);
    const second = try std.fs.path.join(alloc, &.{ root, "second" });
    defer alloc.free(second);

    const result = try (Request{
        .replacement_path = replacement,
        .append_paths = @constCast(&[_][]u8{ first, second }),
    }).compose(alloc, "base");
    switch (result) {
        .failure => return error.TestUnexpectedResult,
        .prompt => |prompt| {
            defer alloc.free(prompt);
            try std.testing.expectEqualStrings("replacement\n\nfirst\n\nsecond", prompt);
        },
    }
}

test "compose preserves the supplied base for append-only requests" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "append", "extra");
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "append");
    defer alloc.free(path);
    const result = try (Request{ .append_paths = @constCast(&[_][]u8{path}) }).compose(alloc, "profile base");
    switch (result) {
        .failure => return error.TestUnexpectedResult,
        .prompt => |prompt| {
            defer alloc.free(prompt);
            try std.testing.expectEqualStrings("profile base\n\nextra", prompt);
        },
    }
}

test "compose rejects invalid model text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "invalid", "bad\x00prompt");
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "invalid");
    defer alloc.free(path);
    const result = try (Request{ .replacement_path = path }).compose(alloc, "base");
    switch (result) {
        .prompt => |prompt| {
            alloc.free(prompt);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| try std.testing.expectEqual(FailureReason.invalid_text, failure.reason),
    }
}

test "compose rejects non-UTF-8 text and non-regular files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "invalid-utf8", "bad\xffprompt");
    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    const invalid_utf8 = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "invalid-utf8");
    defer alloc.free(invalid_utf8);
    const directory = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "directory");
    defer alloc.free(directory);

    const invalid_result = try (Request{ .replacement_path = invalid_utf8 }).compose(alloc, "base");
    switch (invalid_result) {
        .prompt => |prompt| {
            alloc.free(prompt);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| try std.testing.expectEqual(FailureReason.invalid_text, failure.reason),
    }

    const directory_result = try (Request{ .replacement_path = directory }).compose(alloc, "base");
    switch (directory_result) {
        .prompt => |prompt| {
            alloc.free(prompt);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| try std.testing.expectEqual(FailureReason.not_regular_file, failure.reason),
    }
}

test "compose bounds the combined custom prompt bytes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exact_limit = try alloc.alloc(u8, max_custom_bytes);
    defer alloc.free(exact_limit);
    @memset(exact_limit, 'a');
    try writeFile(tmp.dir, "replacement", exact_limit);
    try writeFile(tmp.dir, "append", "x");
    const replacement = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "replacement");
    defer alloc.free(replacement);
    const append = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "append");
    defer alloc.free(append);

    const result = try (Request{
        .replacement_path = replacement,
        .append_paths = @constCast(&[_][]u8{append}),
    }).compose(alloc, "base");
    switch (result) {
        .prompt => |prompt| {
            alloc.free(prompt);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| try std.testing.expectEqual(FailureReason.too_large, failure.reason),
    }
}

test "compose permits an empty file at the exact combined byte limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exact_limit = try alloc.alloc(u8, max_custom_bytes);
    defer alloc.free(exact_limit);
    @memset(exact_limit, 'a');
    try writeFile(tmp.dir, "replacement", exact_limit);
    try writeFile(tmp.dir, "empty-append", "");
    const replacement = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "replacement");
    defer alloc.free(replacement);
    const append = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "empty-append");
    defer alloc.free(append);

    const result = try (Request{
        .replacement_path = replacement,
        .append_paths = @constCast(&[_][]u8{append}),
    }).compose(alloc, "base");
    switch (result) {
        .failure => return error.TestUnexpectedResult,
        .prompt => |prompt| {
            defer alloc.free(prompt);
            try std.testing.expectEqual(max_custom_bytes, prompt.len);
        },
    }
}
