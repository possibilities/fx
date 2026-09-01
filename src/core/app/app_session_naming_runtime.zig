//! Interactive app adapter for native session naming.

const std = @import("std");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session_naming = @import("../session/session_naming.zig");

/// One launch-owned native display name waiting for the fresh or exactly
/// resumed writable session. The source is nulled when ownership transfers.
pub const PendingLaunchName = struct {
    value: ?[]u8 = null,

    pub fn adopt(self: *PendingLaunchName, source: *?[]u8) void {
        std.debug.assert(self.value == null);
        self.value = source.*;
        source.* = null;
    }

    pub fn deinit(self: *PendingLaunchName, alloc: std.mem.Allocator) void {
        if (self.value) |name| alloc.free(name);
        self.* = .{};
    }

    /// Returns an owned relaunch snapshot only while the explicit launch name
    /// is still waiting for durable persistence. The caller owns the bytes.
    pub fn cloneForRelaunch(
        self: *const PendingLaunchName,
        alloc: std.mem.Allocator,
    ) std.mem.Allocator.Error!?[]u8 {
        const name = self.value orelse return null;
        return try alloc.dupe(u8, name);
    }
};

pub fn Runtime(comptime App: type) type {
    return struct {
        const SessionRuntime = app_session_runtime.Runtime(App);

        pub fn adoptPendingLaunchName(app: *App, source: *?[]u8) void {
            app.pending_launch_session_name.adopt(source);
        }

        /// Persists through the same authority as `/rename`, then consumes the
        /// startup-only value so later `/new` operations cannot inherit it.
        pub fn applyPendingLaunchName(app: *App) !void {
            const name = app.pending_launch_session_name.value orelse return;
            try SessionRuntime.renameActiveSession(app, name);
            app.pending_launch_session_name.deinit(app.alloc);
        }

        pub fn discardPendingLaunchName(app: *App) void {
            app.pending_launch_session_name.deinit(app.alloc);
        }

        pub fn clonePendingLaunchNameForRelaunch(
            app: *const App,
            alloc: std.mem.Allocator,
        ) std.mem.Allocator.Error!?[]u8 {
            return app.pending_launch_session_name.cloneForRelaunch(alloc);
        }

        pub fn configure(app: *App, config: session_naming.Config) void {
            app.session_naming.configure(app.alloc, config);
        }

        pub fn prepareAdmission(
            app: *App,
            prompt: []const u8,
        ) !?session_naming.PreparedAdmission {
            // A picker cancellation can leave the explicit title pending after
            // a transient persistence failure. Retry it before admitting the
            // first prompt so automatic naming can never replace it.
            try applyPendingLaunchName(app);
            if (SessionRuntime.cachedSessionTitle(app) != null) return null;
            const session_id = SessionRuntime.activeSessionId(app) orelse return null;
            const credential = app.auth.gatewayCredential() orelse return null;
            return app.session_naming.prepareAdmission(.{
                .session_id = session_id,
                .prompt = prompt,
                .workspace_root = app.workspace_root,
                .home_dir = io_mod.getenv("HOME"),
                .provider_id = provider_runtime.provider(app),
                .provider = app.agentStreamProvider(),
                .credential = .{
                    .secret = credential.api_key,
                    .source = credential.source,
                    .account_id = app.auth.accountId(),
                    .tenant = credential.gateway_team,
                },
            }) catch |err| {
                debug_trace.logf(
                    "session_naming",
                    "admission preparation skipped err={s}",
                    .{@errorName(err)},
                );
                return null;
            };
        }

        pub fn admit(
            app: *App,
            prepared: *session_naming.PreparedAdmission,
        ) void {
            app.session_naming.admit(prepared);
        }

        pub fn invalidate(app: *App) void {
            app.session_naming.invalidate();
        }

        pub fn collectFacts(app: *App) void {
            var completed = app.session_naming.collect(SessionRuntime.activeSessionId(app)) orelse
                return;
            defer completed.deinit();
            const active_id = SessionRuntime.activeSessionId(app) orelse return;
            if (!std.mem.eql(u8, active_id, completed.session_id)) return;
            SessionRuntime.applyGeneratedSessionTitle(app, completed.title) catch |err| {
                debug_trace.logf(
                    "session_naming",
                    "title adoption failed session={s} err={s}",
                    .{ completed.session_id, @errorName(err) },
                );
            };
        }

        pub fn requestStop(app: *App) void {
            app.session_naming.requestStop();
        }

        pub fn deinit(app: *App) void {
            app.session_naming.deinit();
        }
    };
}

test "pending launch name transfers ownership once and clears without leakage" {
    const alloc = std.testing.allocator;
    var source: ?[]u8 = try alloc.dupe(u8, "Native launch title");
    defer if (source) |value| alloc.free(value);

    var pending: PendingLaunchName = .{};
    defer pending.deinit(alloc);
    pending.adopt(&source);

    try std.testing.expect(source == null);
    try std.testing.expectEqualStrings("Native launch title", pending.value.?);
    const relaunch_copy = (try pending.cloneForRelaunch(alloc)).?;
    defer alloc.free(relaunch_copy);
    try std.testing.expectEqualStrings("Native launch title", relaunch_copy);
    pending.deinit(alloc);
    try std.testing.expect(pending.value == null);
    try std.testing.expectEqualStrings("Native launch title", relaunch_copy);
    try std.testing.expect((try pending.cloneForRelaunch(alloc)) == null);
}
