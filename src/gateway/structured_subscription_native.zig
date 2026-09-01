const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const host = @import("../core/hosts/host.zig");
const structured = @import("../core/inference/structured_subscription.zig");
const structured_cli = @import("../core/inference/structured_subscription_cli.zig");
const model_provider = @import("../core/config/model_provider.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const io_mod = @import("../core/shared/io.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const openai_codex_models = @import("openai_codex_models.zig");

const Allocator = std.mem.Allocator;
const state_dir_name = "structured-subscription-inference-v1";
const responses_protocol = "openai-codex-responses-sse-v1";

pub const usage = "usage: fx structured-inference [--state-root <absolute-path>]\n";

pub fn run(
    alloc: Allocator,
    args: []const [:0]const u8,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    providers: provider_set.Set,
) !u8 {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const default_state_root = try std.fs.path.join(alloc, &.{
        home,
        profile_paths.root_dir_name,
        state_dir_name,
    });
    defer alloc.free(default_state_root);
    const options = structured_cli.parseOptions(args, default_state_root) catch {
        try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), usage);
        return 2;
    };
    if (std.mem.eql(u8, options.state_root, default_state_root)) {
        try ensureDefaultStateParent(home);
    }

    const bundle = providers.select(.codex);
    const catalog = bundle.model_catalog orelse return error.CodexModelCatalogUnavailable;
    const responses = bundle.agent_stream orelse return error.CodexResponsesUnavailable;
    var resolver_context = ResolverContext{
        .transport = transport,
        .secret_store = secret_store,
    };
    const dependencies = structured.Dependencies{
        .credential = .{
            .context = &resolver_context,
            .resolve_fn = ResolverContext.resolve,
        },
        .catalog = catalog,
        .responses = responses,
        .catalog_client_version = openai_codex_models.protocol_client_version,
        .provider_protocol = responses_protocol,
    };

    const input = readBoundedStdin(alloc) catch |err| {
        var result = try structured_cli.protocolErrorResult(alloc, @errorName(err));
        defer result.deinit(alloc);
        try writeResult(result.frame);
        return result.exit_code;
    };
    defer alloc.free(input);
    var result = try structured_cli.runFrame(
        alloc,
        input,
        options.state_root,
        dependencies,
    );
    defer result.deinit(alloc);
    try writeResult(result.frame);
    return result.exit_code;
}

const ResolverContext = struct {
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,

    fn resolve(raw: ?*anyopaque, alloc: Allocator) !?credentials.Credential {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var resolution = try credentials.resolveForProvider(
            alloc,
            self.transport,
            self.secret_store,
            .refresh_if_needed,
            model_provider.ProviderId.codex,
            null,
        );
        const credential = resolution.credential;
        resolution.credential = null;
        return credential;
    }
};

fn ensureDefaultStateParent(home: []const u8) !void {
    var home_dir = io_mod.VerifiedDir{
        .dir = try io_mod.openDirAbsoluteNoFollow(home, .{ .iterate = true }),
    };
    defer home_dir.close();
    var profile = try io_mod.openOrCreateVerifiedPrivateDir(
        &home_dir,
        profile_paths.root_dir_name,
    );
    profile.close();
}

fn readBoundedStdin(alloc: Allocator) ![]u8 {
    var buffer: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io_mod.getIo(), &buffer);
    const detection_limit = structured_cli.max_frame_bytes + 1;
    const input = reader.interface.allocRemaining(alloc, .limited(detection_limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StructuredInferenceFrameSizeInvalid,
        else => return error.StructuredInferenceInputReadFailed,
    };
    if (input.len > structured_cli.max_frame_bytes) {
        alloc.free(input);
        return error.StructuredInferenceFrameSizeInvalid;
    }
    return input;
}

fn writeResult(frame: []const u8) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io_mod.getIo(), frame);
    try stdout.writeStreamingAll(io_mod.getIo(), "\n");
}
