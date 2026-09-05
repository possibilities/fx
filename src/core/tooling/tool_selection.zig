const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_set_contract = @import("tool_set.zig");

const Allocator = std.mem.Allocator;

pub const Alias = struct {
    token: []const u8,
    tool: tool_dispatch.Tool,
};

pub const Catalog = struct {
    default_set: tool_set_contract.ToolSet = tool_set_contract.empty,
    aliases: []const Alias = &.{},
};

pub const Issue = union(enum) {
    unknown: []const u8,
    duplicate: []const u8,
    conflict: struct {
        first: []const u8,
        second: []const u8,
    },
};

pub const Resolved = struct {
    tool_set: tool_set_contract.ToolSet = tool_set_contract.empty,
    owns_slices: bool = false,

    pub fn borrowed(tool_set: tool_set_contract.ToolSet) Resolved {
        return .{ .tool_set = tool_set };
    }

    pub fn deinit(self: *Resolved, alloc: Allocator) void {
        if (self.owns_slices) {
            if (self.tool_set.registry.tools.len > 0) alloc.free(self.tool_set.registry.tools);
            if (self.tool_set.order.len > 0) alloc.free(self.tool_set.order);
            if (self.tool_set.read_only_tool_names.len > 0) alloc.free(self.tool_set.read_only_tool_names);
        }
        self.* = .{};
    }
};

const Match = struct {
    token: []const u8,
    tool: tool_dispatch.Tool,
};

fn match(catalog: Catalog, token: []const u8) ?Match {
    for (catalog.aliases) |alias| {
        if (std.mem.eql(u8, alias.token, token)) {
            return .{ .token = alias.token, .tool = alias.tool };
        }
    }
    const tool = catalog.default_set.registry.lookup(token) orelse return null;
    return .{ .token = tool.name, .tool = tool.* };
}

pub fn validate(catalog: Catalog, selections: []const []const u8) ?Issue {
    for (selections, 0..) |selection, index| {
        const selected = match(catalog, selection) orelse return .{ .unknown = selection };
        for (selections[0..index]) |previous_selection| {
            const previous = match(catalog, previous_selection) orelse continue;
            if (!std.mem.eql(u8, previous.tool.name, selected.tool.name)) continue;
            if (std.mem.eql(u8, previous.token, selected.token)) {
                return .{ .duplicate = selection };
            }
            return .{ .conflict = .{
                .first = previous_selection,
                .second = selection,
            } };
        }
    }
    return null;
}

pub fn resolve(
    alloc: Allocator,
    catalog: Catalog,
    selections: []const []const u8,
) (Allocator.Error || error{InvalidToolSelection})!Resolved {
    if (selections.len == 0) return Resolved.borrowed(catalog.default_set);
    if (validate(catalog, selections) != null) return error.InvalidToolSelection;

    const tools = try alloc.alloc(tool_dispatch.Tool, selections.len);
    errdefer alloc.free(tools);
    const order = try alloc.alloc([]const u8, selections.len);
    errdefer alloc.free(order);

    var read_only_count: usize = 0;
    for (selections, 0..) |selection, index| {
        const selected = match(catalog, selection) orelse unreachable;
        tools[index] = selected.tool;
        order[index] = selected.tool.name;
        if (nameInSet(catalog.default_set.read_only_tool_names, selected.tool.name)) {
            read_only_count += 1;
        }
    }

    const read_only = try alloc.alloc([]const u8, read_only_count);
    errdefer if (read_only.len > 0) alloc.free(read_only);
    var read_only_index: usize = 0;
    for (order) |name| {
        if (!nameInSet(catalog.default_set.read_only_tool_names, name)) continue;
        read_only[read_only_index] = name;
        read_only_index += 1;
    }

    return .{
        .tool_set = .{
            .registry = .{ .tools = tools },
            .order = order,
            .read_only_tool_names = read_only,
        },
        .owns_slices = true,
    };
}

fn nameInSet(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

test "native tool selections resolve aliases and preserve flag order" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const aliases = [_]Alias{.{
        .token = "terminal:exec",
        .tool = builtin_tools.terminalExecOnlySpec(),
    }};
    const catalog = Catalog{
        .default_set = builtin_tools.advertisement_set,
        .aliases = &aliases,
    };

    var resolved = try resolve(std.testing.allocator, catalog, &.{
        "terminal:exec",
        "read_file",
    });
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), resolved.tool_set.registry.tools.len);
    try std.testing.expectEqualStrings("shell", resolved.tool_set.order[0]);
    try std.testing.expectEqualStrings("read_file", resolved.tool_set.order[1]);
    try std.testing.expectEqual(@as(usize, 1), resolved.tool_set.read_only_tool_names.len);
    try std.testing.expectEqualStrings("read_file", resolved.tool_set.read_only_tool_names[0]);
    try std.testing.expectEqualStrings(
        builtin_tools.terminalExecOnlySpec().description,
        resolved.tool_set.registry.lookup("shell").?.description,
    );

    try std.testing.expect(validate(catalog, &.{"missing"}).? == .unknown);
    try std.testing.expect(validate(catalog, &.{ "read_file", "read_file" }).? == .duplicate);
    try std.testing.expect(validate(catalog, &.{ "shell", "terminal:exec" }).? == .conflict);
}

fn checkNativeToolResolutionAllocationFailures(alloc: Allocator) !void {
    const builtin_tools = @import("../../builtins/tools.zig");
    const aliases = [_]Alias{.{
        .token = "terminal:exec",
        .tool = builtin_tools.terminalExecOnlySpec(),
    }};
    var resolved = try resolve(alloc, .{
        .default_set = builtin_tools.advertisement_set,
        .aliases = &aliases,
    }, &.{ "terminal:exec", "read_file" });
    resolved.deinit(alloc);
}

test "native tool resolution is allocation safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkNativeToolResolutionAllocationFailures,
        .{},
    );
}
