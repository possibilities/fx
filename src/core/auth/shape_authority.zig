//! Derives the non-secret identity of an agent shape: the resolved system
//! prompt, skill roots, MCP configuration, tool selection, and permission
//! policy that together decide how an instance behaves. Credential authority
//! answers who a request is billed to; shape authority answers what the agent
//! was while it made the request. A session records both, so one history can
//! be read back by the combination that produced each turn.
//!
//! The digest covers the resolved shape *declaration*, not a deep walk of every
//! file it names. System prompt text is hashed by content, because it is read
//! at launch anyway and is the largest single lever on behavior. Skill roots,
//! the MCP configuration path, and the permission policy path are hashed as
//! paths: editing a skill in place keeps the shape identity stable, which is
//! what grouping a history by shape wants. Auditing what a skill said on a
//! given day is the session transcript's job, not this digest's.
const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

const domain = "fx-shape-authority-v1\x00";

/// The default label for a launch that shapes nothing.
pub const default_label = "default";
/// The label for a launch shaped by flags rather than by a named shape root.
pub const custom_label = "custom";
/// Bounds a stored label so a session record cannot carry an unbounded name.
pub const max_label_bytes: usize = 64;

pub const Identity = struct {
    bytes: [Sha256.digest_length]u8,

    pub fn eql(self: Identity, other: Identity) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// A stored shape reference: the operator's label plus the digest that is the
/// authority. The label exists so a history reads back in words; two records
/// are the same shape when their digests match, never when their labels do.
pub const Reference = struct {
    id: []u8,
    identity: Identity,

    pub fn deinit(self: *Reference, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }

    pub fn dupe(self: Reference, alloc: std.mem.Allocator) !Reference {
        return .{ .id = try alloc.dupe(u8, self.id), .identity = self.identity };
    }

    pub fn eql(self: Reference, other: Reference) bool {
        return self.identity.eql(other.identity);
    }
};

/// The resolved shape inputs, in the form the launch layer already holds them.
/// Every field is borrowed for the duration of the call.
pub const Declaration = struct {
    /// Resolved system prompt text, whether it replaces or extends the base.
    system_prompt: ?[]const u8 = null,
    /// True when the resolved prompt replaces Fx's built-in prompt.
    system_prompt_replaces_base: bool = false,
    /// Invocation skill roots, in selection order.
    skill_roots: []const []const u8 = &.{},
    default_skills_enabled: bool = true,
    /// The MCP configuration file backing this shape, when one was selected.
    mcp_config_path: ?[]const u8 = null,
    native_tools_enabled: bool = true,
    /// Explicitly selected native tools, in selection order.
    selected_tools: []const []const u8 = &.{},
    permissions_path: ?[]const u8 = null,
    project_instructions_enabled: bool = true,
};

/// Reports whether a declaration leaves the compiled-in shape untouched. An
/// unshaped launch still gets a digest, so grouping never has a null bucket.
pub fn isDefault(declaration: Declaration) bool {
    return declaration.system_prompt == null and
        declaration.skill_roots.len == 0 and
        declaration.default_skills_enabled and
        declaration.mcp_config_path == null and
        declaration.native_tools_enabled and
        declaration.selected_tools.len == 0 and
        declaration.permissions_path == null and
        declaration.project_instructions_enabled;
}

pub fn derive(declaration: Declaration) Identity {
    var hash = Sha256.init(.{});
    hash.update(domain);
    updateOptional(&hash, "prompt", declaration.system_prompt);
    updateFlag(&hash, "prompt_replaces_base", declaration.system_prompt_replaces_base);
    updateList(&hash, "skills", declaration.skill_roots);
    updateFlag(&hash, "default_skills", declaration.default_skills_enabled);
    updateOptional(&hash, "mcp", declaration.mcp_config_path);
    updateFlag(&hash, "native_tools", declaration.native_tools_enabled);
    updateList(&hash, "tools", declaration.selected_tools);
    updateOptional(&hash, "permissions", declaration.permissions_path);
    updateFlag(&hash, "project_instructions", declaration.project_instructions_enabled);
    var bytes: [Sha256.digest_length]u8 = undefined;
    hash.final(&bytes);
    return .{ .bytes = bytes };
}

/// The identity of a launch that shapes nothing.
pub fn defaultIdentity() Identity {
    return derive(.{});
}

/// Reduces a shape root to a storable label. The basename names the shape the
/// way the operator selected it; a name that cannot be stored falls back to the
/// custom label rather than truncating into a different shape's name.
pub fn labelFromRoot(root: []const u8) []const u8 {
    const trimmed = trimTrailingSeparators(root);
    if (trimmed.len == 0) return custom_label;
    const base = std.fs.path.basename(trimmed);
    if (base.len == 0 or base.len > max_label_bytes) return custom_label;
    if (!std.unicode.utf8ValidateSlice(base)) return custom_label;
    for (base) |byte| {
        if (byte < 0x20 or byte == 0x7f) return custom_label;
    }
    return base;
}

/// The label for a declaration with no named shape root behind it.
pub fn labelForDeclaration(declaration: Declaration) []const u8 {
    return if (isDefault(declaration)) default_label else custom_label;
}

/// Rejects a label that a session record may not carry.
pub fn validateLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > max_label_bytes) return error.InvalidShapeLabel;
    if (!std.unicode.utf8ValidateSlice(label)) return error.InvalidShapeLabel;
    for (label) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidShapeLabel;
    }
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn updateLength(hash: *Sha256, value: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn updateField(hash: *Sha256, tag: []const u8, value: []const u8) void {
    hash.update("\x00");
    hash.update(tag);
    hash.update("\x00");
    updateLength(hash, value.len);
    hash.update(value);
}

fn updateOptional(hash: *Sha256, tag: []const u8, value: ?[]const u8) void {
    if (value) |present| {
        updateField(hash, tag, present);
    } else {
        hash.update("\x00");
        hash.update(tag);
        hash.update("\x00absent\x00");
    }
}

fn updateFlag(hash: *Sha256, tag: []const u8, value: bool) void {
    updateField(hash, tag, if (value) "1" else "0");
}

fn updateList(hash: *Sha256, tag: []const u8, values: []const []const u8) void {
    hash.update("\x00");
    hash.update(tag);
    hash.update("\x00");
    updateLength(hash, values.len);
    for (values) |value| {
        updateLength(hash, value.len);
        hash.update(value);
    }
}

test "an unshaped launch has one stable default identity" {
    const first = defaultIdentity();
    const second = derive(.{});
    try std.testing.expect(first.eql(second));
    try std.testing.expect(isDefault(.{}));
    try std.testing.expect(@sizeOf(Identity) == 32);
}

test "each shape input changes the derived identity" {
    const base = defaultIdentity();
    const cases = [_]Declaration{
        .{ .system_prompt = "be terse" },
        .{ .system_prompt = "be terse", .system_prompt_replaces_base = true },
        .{ .skill_roots = &.{"/shapes/review"} },
        .{ .default_skills_enabled = false },
        .{ .mcp_config_path = "/shapes/review/.fx/mcp.json" },
        .{ .native_tools_enabled = false },
        .{ .selected_tools = &.{"read"} },
        .{ .permissions_path = "/shapes/review/permissions.json" },
        .{ .project_instructions_enabled = false },
    };
    var seen: [cases.len]Identity = undefined;
    for (cases, 0..) |declaration, index| {
        const identity = derive(declaration);
        try std.testing.expect(!identity.eql(base));
        try std.testing.expect(!isDefault(declaration));
        for (seen[0..index]) |earlier| {
            try std.testing.expect(!identity.eql(earlier));
        }
        seen[index] = identity;
    }
}

test "list fields cannot be confused by concatenation" {
    const split = derive(.{ .skill_roots = &.{ "a", "bc" } });
    const joined = derive(.{ .skill_roots = &.{"abc"} });
    const reordered = derive(.{ .skill_roots = &.{ "bc", "a" } });
    try std.testing.expect(!split.eql(joined));
    try std.testing.expect(!split.eql(reordered));
}

test "an absent optional differs from an empty one" {
    const absent = derive(.{ .system_prompt = null });
    const empty = derive(.{ .system_prompt = "" });
    try std.testing.expect(!absent.eql(empty));
}

test "identity is stable across equal declarations" {
    const roots = [_][]const u8{ "/shapes/review/.fx/skills", "/shared/skills" };
    const declaration = Declaration{
        .system_prompt = "review carefully",
        .skill_roots = &roots,
        .mcp_config_path = "/shapes/review/.fx/mcp.json",
        .selected_tools = &.{ "read", "grep" },
    };
    try std.testing.expect(derive(declaration).eql(derive(declaration)));
}

test "shape labels come from the selected root" {
    try std.testing.expectEqualStrings("reviewer", labelFromRoot("/shapes/reviewer"));
    try std.testing.expectEqualStrings("reviewer", labelFromRoot("/shapes/reviewer/"));
    try std.testing.expectEqualStrings(custom_label, labelFromRoot("/"));
    try std.testing.expectEqualStrings(custom_label, labelFromRoot(""));
    try std.testing.expectEqualStrings(custom_label, labelFromRoot("/shapes/" ++ "n" ** 65));
    try std.testing.expectEqualStrings(default_label, labelForDeclaration(.{}));
    try std.testing.expectEqualStrings(
        custom_label,
        labelForDeclaration(.{ .system_prompt = "be terse" }),
    );
}

test "stored labels reject control characters and overlong names" {
    try validateLabel("default");
    try validateLabel("work reviewer");
    try std.testing.expectError(error.InvalidShapeLabel, validateLabel(""));
    try std.testing.expectError(error.InvalidShapeLabel, validateLabel("bad\nname"));
    try std.testing.expectError(error.InvalidShapeLabel, validateLabel("n" ** 65));
    try std.testing.expectError(error.InvalidShapeLabel, validateLabel(&.{ 0xff, 0xfe }));
}

test "a stored reference compares by digest, never by label" {
    const identity = derive(.{ .system_prompt = "review carefully" });
    const other = derive(.{ .system_prompt = "build quickly" });
    const named = Reference{ .id = @constCast("reviewer"), .identity = identity };
    const renamed = Reference{ .id = @constCast("review"), .identity = identity };
    const relabelled = Reference{ .id = @constCast("reviewer"), .identity = other };
    try std.testing.expect(named.eql(renamed));
    try std.testing.expect(!named.eql(relabelled));
}
