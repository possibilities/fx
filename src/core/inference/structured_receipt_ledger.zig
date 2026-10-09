const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const ledger_schema_id = "fx.structured-subscription-inference-ledger";
pub const ledger_version: u32 = 1;
pub const max_terminal_frame_bytes: usize = 1024 * 1024;

const lock_deadline_ms: u64 = 2_000;
const max_record_bytes: usize = max_terminal_frame_bytes * 2 + 16 * 1024;

pub const Phase = enum {
    started,
    provider_admitted,
    terminal,
};

pub const Record = struct {
    request_digest: [Sha256.digest_length]u8,
    phase: Phase,
    terminal_frame: ?[]u8 = null,
    acknowledged: bool = false,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        if (self.terminal_frame) |frame| alloc.free(frame);
        self.* = undefined;
    }
};

pub const Store = struct {
    dir: io_mod.VerifiedDir,

    /// Opens or creates the final private directory. The parent must already
    /// exist and `root_path` must be absolute.
    pub fn init(root_path: []const u8) !Store {
        if (!std.fs.path.isAbsolute(root_path)) return error.InvalidStateRoot;
        const parent_path = std.fs.path.dirname(root_path) orelse return error.InvalidStateRoot;
        const leaf = std.fs.path.basename(root_path);
        if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) {
            return error.InvalidStateRoot;
        }

        var parent = io_mod.VerifiedDir{
            .dir = try io_mod.openDirAbsoluteNoFollow(parent_path, .{ .iterate = true }),
        };
        defer parent.close();
        return .{ .dir = try io_mod.openOrCreateVerifiedPrivateDir(&parent, leaf) };
    }

    pub fn deinit(self: *Store) void {
        self.dir.close();
        self.* = undefined;
    }

    pub fn lock(self: *Store, alloc: Allocator, caller_key: []const u8) !LockedEntry {
        if (caller_key.len == 0 or caller_key.len > 1024) return error.InvalidCallerKey;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(caller_key, &digest, .{});
        const key_hex = std.fmt.bytesToHex(digest, .lower);
        const record_name = try std.fmt.allocPrint(alloc, "{s}.json", .{key_hex});
        errdefer alloc.free(record_name);
        const lock_name = try std.fmt.allocPrint(alloc, "{s}.lock", .{key_hex});
        defer alloc.free(lock_name);
        const held = io_mod.acquireTimedAdvisoryLock(&self.dir, lock_name, lock_deadline_ms) catch |err| switch (err) {
            error.LockBusy => return error.StructuredInferenceKeyBusy,
            error.LockUnsupported => return error.StructuredInferenceLockUnsupported,
            else => return err,
        };
        return .{
            .alloc = alloc,
            .store = self,
            .record_name = record_name,
            .held = held,
        };
    }
};

pub const LockedEntry = struct {
    alloc: Allocator,
    store: *Store,
    record_name: []u8,
    held: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *LockedEntry) void {
        self.held.release();
        self.alloc.free(self.record_name);
        self.* = undefined;
    }

    /// Returns an owned record when present.
    pub fn load(self: *LockedEntry) !?Record {
        const zio = io_mod.getIo();
        var file = self.store.dir.dir.openFile(zio, self.record_name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.SymLinkLoop, error.IsDir, error.NotDir => return error.StructuredInferenceLedgerCorrupt,
            else => return err,
        };
        defer file.close(zio);
        const stat = try file.stat(zio);
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) {
            return error.StructuredInferenceLedgerCorrupt;
        }
        const bytes = io_mod.readFileToEnd(self.alloc, &file, max_record_bytes) catch |err| switch (err) {
            error.StreamTooLong => return error.StructuredInferenceLedgerCorrupt,
            else => return err,
        };
        defer self.alloc.free(bytes);
        return try decodeRecord(self.alloc, bytes);
    }

    pub fn save(self: *LockedEntry, record: Record) !void {
        const bytes = try encodeRecord(self.alloc, record);
        defer self.alloc.free(bytes);
        try io_mod.durableReplaceVerified(self.alloc, &self.store.dir, self.record_name, bytes);
    }
};

fn encodeRecord(alloc: Allocator, record: Record) ![]u8 {
    if (record.phase == .terminal and record.terminal_frame == null) {
        return error.StructuredInferenceLedgerCorrupt;
    }
    if (record.phase != .terminal and record.terminal_frame != null) {
        return error.StructuredInferenceLedgerCorrupt;
    }
    if (record.terminal_frame) |frame| {
        if (frame.len == 0 or frame.len > max_terminal_frame_bytes) {
            return error.StructuredInferenceLedgerCorrupt;
        }
    }

    const digest_hex = std.fmt.bytesToHex(record.request_digest, .lower);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema_id\":");
    try std.json.Stringify.value(ledger_schema_id, .{}, &out.writer);
    try out.writer.print(",\"version\":{d},\"request_digest\":", .{ledger_version});
    try std.json.Stringify.value(&digest_hex, .{}, &out.writer);
    try out.writer.writeAll(",\"phase\":");
    try std.json.Stringify.value(@tagName(record.phase), .{}, &out.writer);
    try out.writer.writeAll(",\"terminal_frame\":");
    if (record.terminal_frame) |frame| {
        try std.json.Stringify.value(frame, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.print(",\"acknowledged\":{s}}}", .{if (record.acknowledged) "true" else "false"});
    if (out.written().len > max_record_bytes) return error.StructuredInferenceLedgerCorrupt;
    return out.toOwnedSlice();
}

fn decodeRecord(alloc: Allocator, bytes: []const u8) !Record {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.StructuredInferenceLedgerCorrupt;
    defer parsed.deinit();
    if (parsed.value != .object) return error.StructuredInferenceLedgerCorrupt;
    const object = parsed.value.object;
    if (object.count() != 6 or
        !std.mem.eql(u8, try objectString(object, "schema_id"), ledger_schema_id) or
        try objectUnsigned(object, "version") != ledger_version)
    {
        return error.StructuredInferenceLedgerCorrupt;
    }

    var request_digest: [Sha256.digest_length]u8 = undefined;
    const digest_text = try objectString(object, "request_digest");
    if (digest_text.len != request_digest.len * 2) return error.StructuredInferenceLedgerCorrupt;
    _ = std.fmt.hexToBytes(&request_digest, digest_text) catch
        return error.StructuredInferenceLedgerCorrupt;
    const canonical_digest = std.fmt.bytesToHex(request_digest, .lower);
    if (!std.mem.eql(u8, digest_text, &canonical_digest)) return error.StructuredInferenceLedgerCorrupt;

    const phase_text = try objectString(object, "phase");
    const phase = std.meta.stringToEnum(Phase, phase_text) orelse
        return error.StructuredInferenceLedgerCorrupt;
    const terminal_value = object.get("terminal_frame") orelse
        return error.StructuredInferenceLedgerCorrupt;
    const terminal_frame = switch (terminal_value) {
        .null => null,
        .string => |frame| blk: {
            if (frame.len == 0 or frame.len > max_terminal_frame_bytes) {
                return error.StructuredInferenceLedgerCorrupt;
            }
            break :blk try alloc.dupe(u8, frame);
        },
        else => return error.StructuredInferenceLedgerCorrupt,
    };
    errdefer if (terminal_frame) |frame| alloc.free(frame);
    const acknowledged_value = object.get("acknowledged") orelse
        return error.StructuredInferenceLedgerCorrupt;
    if (acknowledged_value != .bool) return error.StructuredInferenceLedgerCorrupt;
    if ((phase == .terminal) != (terminal_frame != null)) {
        return error.StructuredInferenceLedgerCorrupt;
    }
    if (phase != .terminal and acknowledged_value.bool) {
        return error.StructuredInferenceLedgerCorrupt;
    }
    return .{
        .request_digest = request_digest,
        .phase = phase,
        .terminal_frame = terminal_frame,
        .acknowledged = acknowledged_value.bool,
    };
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.StructuredInferenceLedgerCorrupt;
    if (value != .string) return error.StructuredInferenceLedgerCorrupt;
    return value.string;
}

fn objectUnsigned(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.StructuredInferenceLedgerCorrupt;
    if (value != .integer or value.integer < 0) return error.StructuredInferenceLedgerCorrupt;
    return @intCast(value.integer);
}

test "structured inference receipt ledger persists phases terminal replay and acknowledgement" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(parent);
    const root = try std.fs.path.join(alloc, &.{ parent, "structured-state" });
    defer alloc.free(root);

    var store = try Store.init(root);
    defer store.deinit();
    var entry = try store.lock(alloc, "opaque-key");
    defer entry.deinit();
    try std.testing.expect((try entry.load()) == null);

    var request_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("request", &request_digest, .{});
    try entry.save(.{ .request_digest = request_digest, .phase = .started });
    var started = (try entry.load()).?;
    defer started.deinit(alloc);
    try std.testing.expectEqual(Phase.started, started.phase);

    try entry.save(.{ .request_digest = request_digest, .phase = .provider_admitted });
    const terminal_frame = try alloc.dupe(u8, "{\"status\":\"succeeded\"}");
    defer alloc.free(terminal_frame);
    try entry.save(.{
        .request_digest = request_digest,
        .phase = .terminal,
        .terminal_frame = terminal_frame,
    });
    var terminal = (try entry.load()).?;
    defer terminal.deinit(alloc);
    try std.testing.expectEqualStrings("{\"status\":\"succeeded\"}", terminal.terminal_frame.?);

    try entry.save(.{
        .request_digest = request_digest,
        .phase = .terminal,
        .terminal_frame = terminal.terminal_frame,
        .acknowledged = true,
    });
    var acknowledged = (try entry.load()).?;
    defer acknowledged.deinit(alloc);
    try std.testing.expect(acknowledged.acknowledged);
}
