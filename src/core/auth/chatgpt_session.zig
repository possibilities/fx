const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const js_host_auth = @import("js_host_auth.zig");
const secret = @import("secret.zig");
const session_presence = @import("session_presence.zig");

const Allocator = std.mem.Allocator;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const expiry_skew_ms: i64 = 60 * 1000;
const mutation_lock_file_name = "chatgpt-auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;

pub const issuer = "https://auth.openai.com";
pub const auth_file_name = profile_paths.chatgpt_auth_file_name;

pub fn presence() host.SecretStorePresence {
    return session_presence.profileFile(auth_file_name, max_auth_file_bytes);
}

pub fn refreshDeadlineMs(expires_at_ms: i64) i64 {
    return @max(expires_at_ms - expiry_skew_ms, 0);
}

pub const Session = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    account_id: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refreshDeadlineMs(self.expires_at_ms) <= now_ms;
    }
};

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

const ProfileMutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *ProfileMutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *ProfileMutation, alloc: Allocator) !?Session {
        return loadFromDir(alloc, &self.fx_dir.dir, true);
    }

    pub fn save(self: *ProfileMutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, auth_file_name, text);
    }

    pub fn delete(self: *ProfileMutation) !DeleteOutcome {
        self.fx_dir.dir.deleteFile(io_mod.getIo(), auth_file_name) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        const durable: io_mod.DurableOps = .{};
        durable.sync_dir(durable.ctx, self.fx_dir.dir) catch return .deleted_not_durable;
        return .deleted;
    }
};

const HostMutation = struct {
    store: js_host_auth.SessionStore,
    revision: [js_host_auth.max_revision_bytes]u8 = undefined,
    revision_len: usize = 0,
    exists: bool = false,

    fn init(store: js_host_auth.SessionStore) HostMutation {
        return .{ .store = store };
    }

    fn deinit(self: *HostMutation) void {
        @memset(&self.revision, 0);
        self.* = undefined;
    }

    fn load(self: *HostMutation, alloc: Allocator) !?Session {
        var stored = (try self.store.load(alloc)) orelse {
            self.exists = false;
            self.revision_len = 0;
            return null;
        };
        defer stored.deinit(alloc);
        try self.captureRevision(stored.revision);
        return parse(alloc, stored.bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidChatGptAuthSession,
        };
    }

    fn save(self: *HostMutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        const expected = if (self.exists) self.revision[0..self.revision_len] else null;
        const revision = try self.store.commit(alloc, text, expected);
        defer alloc.free(revision);
        try self.captureRevision(revision);
    }

    fn captureStoredRevision(self: *HostMutation, alloc: Allocator) !void {
        var stored = (try self.store.load(alloc)) orelse {
            self.exists = false;
            self.revision_len = 0;
            return;
        };
        defer stored.deinit(alloc);
        try self.captureRevision(stored.revision);
    }

    fn captureRevision(self: *HostMutation, revision: []const u8) !void {
        if (revision.len > self.revision.len) return error.OAuthSessionRevisionTooLarge;
        @memcpy(self.revision[0..revision.len], revision);
        self.revision_len = revision.len;
        self.exists = true;
    }
};

pub const Mutation = union(enum) {
    profile: ProfileMutation,
    host: HostMutation,

    pub fn deinit(self: *Mutation) void {
        switch (self.*) {
            .profile => |*mutation| mutation.deinit(),
            .host => |*mutation| mutation.deinit(),
        }
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        return switch (self.*) {
            .profile => |*mutation| mutation.load(alloc),
            .host => |*mutation| mutation.load(alloc),
        };
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        return switch (self.*) {
            .profile => |*mutation| mutation.save(alloc, session),
            .host => |*mutation| mutation.save(alloc, session),
        };
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        return switch (self.*) {
            .profile => |*mutation| mutation.delete(),
            .host => error.OAuthSessionStoreUnavailable,
        };
    }
};

pub const Store = union(enum) {
    /// The existing Fx profile store. A null home preserves ordinary CLI
    /// behavior by resolving HOME at the point of use.
    profile: ?[]const u8,
    /// An explicit host store, used by native libfx without ambient disk reads.
    host: js_host_auth.SessionStore,
};

pub const default_store: Store = .{ .profile = null };

pub fn load(alloc: Allocator) !?Session {
    return loadFromStore(alloc, default_store);
}

pub fn loadFromStore(alloc: Allocator, store: Store) !?Session {
    return switch (store) {
        .profile => |configured_home| loadFromProfile(alloc, configured_home),
        .host => |host_store| loadFromHost(alloc, host_store),
    };
}

fn loadFromHost(alloc: Allocator, store: js_host_auth.SessionStore) !?Session {
    var stored = (try store.load(alloc)) orelse return null;
    defer stored.deinit(alloc);
    return parse(alloc, stored.bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "ChatGPT host session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

fn loadFromProfile(alloc: Allocator, configured_home: ?[]const u8) !?Session {
    if (comptime host_target.is_wasm) return null;
    const home = configured_home orelse io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "ChatGPT session load failed step=open_home err={s}", .{@errorName(err)});
        return null;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err != error.FileNotFound) {
            debug_trace.logf("auth", "ChatGPT session load failed step=open_profile err={s}", .{@errorName(err)});
        }
        return null;
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir, false);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir, report_open_failure: bool) !?Session {
    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "ChatGPT session load failed step=open_file err={s}", .{@errorName(err)});
            if (report_open_failure) return err;
            return null;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "ChatGPT session load failed step=permissions err=InsecureAuthFile", .{});
        return null;
    }

    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "ChatGPT session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    return saveNewSessionToStore(alloc, default_store, session);
}

pub fn saveNewSessionToStore(alloc: Allocator, store: Store, session: Session) !void {
    if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
    var mutation = try beginMutationForStore(alloc, store);
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    return beginExistingMutationForStore(default_store);
}

pub fn beginExistingMutationForStore(store: Store) !?Mutation {
    return switch (store) {
        .profile => |configured_home| beginExistingProfileMutation(configured_home),
        .host => |host_store| @as(?Mutation, .{ .host = HostMutation.init(host_store) }),
    };
}

fn beginExistingProfileMutation(configured_home: ?[]const u8) !?Mutation {
    if (comptime host_target.is_wasm) return null;
    const home = configured_home orelse io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return .{ .profile = try lockMutation(fx_dir) };
}

fn beginMutationForStore(alloc: Allocator, store: Store) !Mutation {
    return switch (store) {
        .profile => |configured_home| .{ .profile = try beginProfileMutation(configured_home) },
        .host => |host_store| host: {
            var mutation = HostMutation.init(host_store);
            errdefer mutation.deinit();
            try mutation.captureStoredRevision(alloc);
            break :host .{ .host = mutation };
        },
    };
}

fn beginProfileMutation(configured_home: ?[]const u8) !ProfileMutation {
    const home = configured_home orelse io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    return lockMutation(fx_dir);
}

fn lockMutation(open_fx_dir: io_mod.VerifiedDir) !ProfileMutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(
        &fx_dir,
        mutation_lock_file_name,
        mutation_lock_deadline_ms,
    );
    errdefer lock.release();
    return .{ .fx_dir = fx_dir, .lock = lock };
}

fn openExistingPrivateFxDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());

    const initial_stat = try dir.stat(io_mod.getIo());
    if (initial_stat.kind != .directory) return error.DurablePathUnsafe;
    if (initial_stat.permissions.toMode() & 0o200 == 0) return error.PrivateStatePermissionsUnsupported;
    dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700)) catch {
        return error.PrivateStatePermissionsUnsupported;
    };
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
    return .{ .dir = dir };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidChatGptAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidChatGptAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidChatGptAuthSession;

    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const account_id = try dupeRequiredString(alloc, object, "account_id");
    errdefer alloc.free(account_id);
    const expires_at_ms = try requiredInteger(object, "expires_at_ms");
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"access_token\":");
    try std.json.Stringify.value(session.access_token, .{}, &out.writer);
    try out.writer.writeAll(",\"refresh_token\":");
    try std.json.Stringify.value(session.refresh_token, .{}, &out.writer);
    try out.writer.print(",\"expires_at_ms\":{d},\"account_id\":", .{session.expires_at_ms});
    try std.json.Stringify.value(session.account_id, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidChatGptAuthSession;
    if (value != .string or value.string.len == 0) return error.InvalidChatGptAuthSession;
    return alloc.dupe(u8, value.string);
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidChatGptAuthSession;
    if (value != .integer) return error.InvalidChatGptAuthSession;
    return value.integer;
}

test "ChatGPT auth session round trips without exposing token fields to structure" {
    const alloc = std.testing.allocator;
    var session = Session{
        .access_token = try alloc.dupe(u8, "header.payload.signature"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_at_ms = 1234,
        .account_id = try alloc.dupe(u8, "acct_123"),
    };
    defer session.deinit(alloc);

    const encoded = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, encoded);
    var decoded = try parse(alloc, encoded);
    defer decoded.deinit(alloc);

    try std.testing.expectEqualStrings(session.access_token, decoded.access_token);
    try std.testing.expectEqualStrings(session.refresh_token, decoded.refresh_token);
    try std.testing.expectEqualStrings(session.account_id, decoded.account_id);
    try std.testing.expectEqual(session.expires_at_ms, decoded.expires_at_ms);
}

test "ChatGPT session refresh deadline keeps a one minute safety margin" {
    try std.testing.expectEqual(@as(i64, 40_000), refreshDeadlineMs(100_000));
    try std.testing.expectEqual(@as(i64, 0), refreshDeadlineMs(10_000));
}
