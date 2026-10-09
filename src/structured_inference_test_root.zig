test {
    _ = @import("core/inference/structured_schema.zig");
    _ = @import("core/inference/structured_receipt_ledger.zig");
    _ = @import("core/inference/structured_subscription.zig");
    _ = @import("core/inference/structured_subscription_cli.zig");
    _ = @import("gateway/responses_protocol.zig");
    _ = @import("gateway/structured_subscription_native.zig");
    _ = @import("core/cli/cli_surface.zig");
    _ = @import("core/slash_commands/command_specs.zig");
    _ = @import("builtins/commands.zig");
}
