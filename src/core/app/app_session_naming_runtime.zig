//! Interactive app adapter for native session naming.

const std = @import("std");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session_naming = @import("../session/session_naming.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        const SessionRuntime = app_session_runtime.Runtime(App);

        pub fn configure(app: *App, config: session_naming.Config) void {
            app.session_naming.configure(app.alloc, config);
        }

        pub fn prepareAdmission(
            app: *App,
            prompt: []const u8,
        ) ?session_naming.PreparedAdmission {
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
                .credential = if (credential.source == .host_managed)
                    .host_managed
                else
                    .{ .direct = .{
                        .secret_bytes = credential.api_key orelse "",
                        .source = credential.source,
                        .account_id = app.auth.accountId(),
                        .tenant_context = credential.gateway_team,
                    } },
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
