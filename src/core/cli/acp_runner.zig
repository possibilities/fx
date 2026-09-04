const std = @import("std");
const chatgpt_session = @import("../auth/chatgpt_session.zig");
const config_runtime = @import("../config/config_runtime.zig");
const process_provider = @import("../execution/process_provider.zig");
const model_provider = @import("../config/model_provider.zig");
const shape_authority = @import("../auth/shape_authority.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const host = @import("../hosts/host.zig");
const credentials = @import("../auth/credentials.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const context_contract = @import("../workspace/context_contract.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    auth_mode: credentials.AuthMode = .local,
    default_model: []const u8,
    default_agent_step_limit: usize,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_models_path: []const u8,
    gateway_provider: gateway_provider.Provider,
    provider_set: provider_set.Set,
    libfx_gateway_model_catalog: ?model_catalog.Provider = null,
    process_provider: process_provider.Provider = process_provider.unavailable_provider,
    secret_store: host.SecretStore,
    prompt_policy: prompt_policy.Policy,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize,
    max_history_turns: usize,
    context_registry: context_contract.Registry,
    mode_registry: mode_registry.Registry,
    model_override: ?[]const u8 = null,
    effort_override: ?types.ReasoningEffort = null,
    provider_override: ?model_provider.ProviderId = null,
    allowed_providers: std.EnumSet(model_provider.ProviderId) = .initFull(),
    credential_override: ?[]const u8 = null,
    chatgpt_session_store: chatgpt_session.Store = chatgpt_session.default_store,
    home_override: ?[]const u8 = null,
    /// The root owning sessions, prompt history, and usage. Null keeps history
    /// with `home_override`, so `--state-dir` still isolates all three.
    history_home_override: ?[]const u8 = null,
    /// The profile whose credential this launch borrows, read only.
    identity_home: ?[]const u8 = null,
    /// Canonical profile MCP configuration selected by the launch shape.
    /// Stored MCP credentials remain with the writable state/profile home.
    mcp_config_path: ?[]const u8 = null,
    /// The shape this launch is running, recorded beside every session.
    shape: ?shape_authority.Identity = null,
    shape_label: []const u8 = shape_authority.default_label,
    workspace_root_override: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    context_limit_overrides: []const config_runtime.context_limits.Override = &.{},
    additional_directories: []const []const u8 = &.{},
    saved_directories_suppressed: bool = false,
    /// Borrowed invocation policy; the server duplicates it during initialize.
    permission_rules_override: ?types.PermissionRuleSet = null,
    skill_root_policy: skill_contract.RootPolicy = .{ .managed_root_source = null },
    allow_acp_mcp: bool = true,
    allow_native_tools: bool = true,
    project_instructions_enabled: bool = true,
    native_tool_set: ?tool_set_contract.ToolSet = null,
    minimal_kernel: bool = false,
};

pub const RunFn = *const fn (?*anyopaque, Allocator, Config) anyerror!void;

pub const Runner = struct {
    context: ?*anyopaque = null,
    run_fn: RunFn,

    pub fn run(self: Runner, alloc: Allocator, cfg: Config) !void {
        return self.run_fn(self.context, alloc, cfg);
    }
};
