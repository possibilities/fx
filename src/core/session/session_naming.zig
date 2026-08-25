//! Best-effort native session naming from the first admitted user prompt.
//!
//! The interactive app owns admission and result adoption. This module owns
//! the bounded provider request, prompt excerpt construction, and task
//! lifetime. Provider work never mutates session state directly.

const std = @import("std");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const secret = @import("../auth/secret.zig");
const model_provider = @import("../config/model_provider.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const excerpt_max_bytes: usize = 1600;
pub const mentioned_file_max_bytes: usize = 2 * 1024;
pub const generated_title_max_bytes: usize = 64;
/// Bytes kept from one naming stream. Twice the slug bound leaves room for a
/// wrapping quote or a short preamble; everything past it is read and dropped
/// rather than kept, so a chatty model costs bytes we ignore and never memory.
pub const capture_max_bytes: usize = generated_title_max_bytes * 2;
pub const default_timeout_ms: u64 = 60_000;
pub const min_timeout_ms: u64 = 1_000;
pub const max_timeout_ms: u64 = 300_000;
pub const default_codex_model = "gpt-5.4-mini";
pub const default_effort = types.ReasoningEffort.literal("low");

/// One retry. A completion that slugs to nothing is usually formatting
/// noise rather than a provider fault, and asking a second time is what
/// makes the slug reliable. Both attempts spend the admission's single
/// deadline, so retrying never extends a task's life.
pub const naming_attempts: usize = 2;

const naming_instruction =
    "Generate a short session title of three to six words that summarizes " ++
    "the work requested in the conversation-opening prompt. Prioritize the " ++
    "user's request, goal, and repeated themes over implementation detail. " ++
    "Respond with only the title text, with no quotes or preamble.";

pub const ProviderSetting = struct {
    specified: bool = false,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,

    pub fn deinit(self: *ProviderSetting, alloc: Allocator) void {
        if (self.model) |value| alloc.free(value);
        self.* = .{};
    }
};

/// Profile-owned, unresolved settings. An explicitly null provider disables
/// its compiled default; an absent provider inherits it.
pub const Settings = struct {
    gateway: ProviderSetting = .{},
    codex: ProviderSetting = .{},
    grok: ProviderSetting = .{},
    timeout_ms: ?u64 = null,

    pub fn deinit(self: *Settings, alloc: Allocator) void {
        self.gateway.deinit(alloc);
        self.codex.deinit(alloc);
        self.grok.deinit(alloc);
        self.* = .{};
    }

    pub fn setting(self: *Settings, provider: model_provider.ProviderId) *ProviderSetting {
        return switch (provider) {
            .gateway => &self.gateway,
            .codex => &self.codex,
            .grok => &self.grok,
        };
    }

    pub fn settingConst(self: *const Settings, provider: model_provider.ProviderId) *const ProviderSetting {
        return switch (provider) {
            .gateway => &self.gateway,
            .codex => &self.codex,
            .grok => &self.grok,
        };
    }
};

pub const ProviderConfig = struct {
    model: ?[]u8 = null,
    effort: types.ReasoningEffort = default_effort,

    pub fn deinit(self: *ProviderConfig, alloc: Allocator) void {
        if (self.model) |value| alloc.free(value);
        self.* = .{};
    }
};

/// Resolved, owned configuration installed once during interactive startup.
pub const Config = struct {
    gateway: ProviderConfig = .{},
    codex: ProviderConfig = .{},
    grok: ProviderConfig = .{},
    timeout_ms: u64 = default_timeout_ms,

    pub fn deinit(self: *Config, alloc: Allocator) void {
        self.gateway.deinit(alloc);
        self.codex.deinit(alloc);
        self.grok.deinit(alloc);
        self.* = .{};
    }

    pub fn provider(self: *const Config, provider_id: model_provider.ProviderId) *const ProviderConfig {
        return switch (provider_id) {
            .gateway => &self.gateway,
            .codex => &self.codex,
            .grok => &self.grok,
        };
    }
};

pub fn resolveConfig(alloc: Allocator, settings: *const Settings) !Config {
    var config = Config{ .timeout_ms = settings.timeout_ms orelse default_timeout_ms };
    errdefer config.deinit(alloc);

    try resolveProviderConfig(alloc, &config.gateway, &settings.gateway, null);
    try resolveProviderConfig(alloc, &config.codex, &settings.codex, default_codex_model);
    try resolveProviderConfig(alloc, &config.grok, &settings.grok, null);
    return config;
}

fn resolveProviderConfig(
    alloc: Allocator,
    target: *ProviderConfig,
    setting: *const ProviderSetting,
    compiled_default_model: ?[]const u8,
) !void {
    const model = if (setting.specified) setting.model else compiled_default_model;
    if (model) |value| target.model = try alloc.dupe(u8, value);
    target.effort = setting.effort orelse default_effort;
}

pub const AdmissionInput = struct {
    session_id: []const u8,
    prompt: []const u8,
    workspace_root: []const u8,
    home_dir: ?[]const u8,
    provider_id: model_provider.ProviderId,
    provider: agent_stream_provider.Provider,
    credential: agent_stream_provider.CredentialLease,
};

pub const PreparedAdmission = struct {
    alloc: ?Allocator = null,
    generation: u64 = 0,
    timeout_ms: u64 = default_timeout_ms,
    session_id: []u8 = &.{},
    prompt: []u8 = &.{},
    workspace_root: []u8 = &.{},
    home_dir: ?[]u8 = null,
    provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    model: []u8 = &.{},
    effort: types.ReasoningEffort = default_effort,
    api_key: []u8 = &.{},
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]u8 = null,
    team: ?[]u8 = null,

    pub fn deinit(self: *PreparedAdmission) void {
        const alloc = self.alloc orelse return;
        if (self.session_id.len > 0) alloc.free(self.session_id);
        if (self.prompt.len > 0) alloc.free(self.prompt);
        if (self.workspace_root.len > 0) alloc.free(self.workspace_root);
        if (self.home_dir) |value| alloc.free(value);
        if (self.model.len > 0) alloc.free(self.model);
        if (self.api_key.len > 0) secret.zeroAndFree(alloc, self.api_key);
        if (self.account_id) |value| alloc.free(value);
        if (self.team) |value| alloc.free(value);
        self.* = .{};
    }
};

pub const CompletedName = struct {
    alloc: Allocator,
    session_id: []u8,
    title: []u8,

    pub fn deinit(self: *CompletedName) void {
        self.alloc.free(self.session_id);
        self.alloc.free(self.title);
        self.* = undefined;
    }
};

const Task = struct {
    alloc: Allocator,
    generation: u64,
    deadline_ns: i128,
    session_id: []u8,
    prompt: []u8,
    workspace_root: []u8,
    home_dir: ?[]u8,
    provider: agent_stream_provider.Provider,
    model: []u8,
    effort: types.ReasoningEffort,
    api_key: []u8,
    credential_source: ?types.CredentialSource,
    account_id: ?[]u8,
    team: ?[]u8,
    /// Ends the task. Set only from outside the naming thread.
    cancel_flag: std.atomic.Value(bool) = .init(false),
    /// Stops the provider call in flight when the task ends. A settled title
    /// does not set it: the stream is read to its own completion.
    attempt_cancel: std.atomic.Value(bool) = .init(false),
    captured_title: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    title: ?[]u8 = null,
    thread: ?std.Thread = null,

    fn fromPrepared(prepared: *PreparedAdmission) Task {
        const task = Task{
            .alloc = prepared.alloc.?,
            .generation = prepared.generation,
            .deadline_ns = io_mod.nanoTimestamp() +
                @as(i128, @intCast(prepared.timeout_ms)) * std.time.ns_per_ms,
            .session_id = prepared.session_id,
            .prompt = prepared.prompt,
            .workspace_root = prepared.workspace_root,
            .home_dir = prepared.home_dir,
            .provider = prepared.provider,
            .model = prepared.model,
            .effort = prepared.effort,
            .api_key = prepared.api_key,
            .credential_source = prepared.credential_source,
            .account_id = prepared.account_id,
            .team = prepared.team,
        };
        prepared.* = .{};
        return task;
    }

    /// Ends the task and stops the attempt in flight. `cancel_flag` is set
    /// first so a naming thread that observes the stopped attempt also sees
    /// that the task itself is over.
    fn cancel(self: *Task) void {
        self.cancel_flag.store(true, .seq_cst);
        self.attempt_cancel.store(true, .seq_cst);
    }

    /// Milliseconds left of the admission's one budget; zero once spent.
    fn remainingMs(self: *const Task) u64 {
        const left = self.deadline_ns - io_mod.nanoTimestamp();
        if (left <= 0) return 0;
        return @intCast(@divTrunc(left, std.time.ns_per_ms));
    }

    fn run(self: *Task) void {
        self.title = inferTitle(self) catch |err| blk: {
            if (err != error.Cancelled and !self.cancel_flag.load(.seq_cst)) {
                @import("../shared/debug_trace.zig").logf(
                    "session_naming",
                    "inference failed session={s} err={s}",
                    .{ self.session_id, @errorName(err) },
                );
            }
            break :blk null;
        };
        self.done.store(true, .seq_cst);
    }

    fn deinit(self: *Task) void {
        if (self.title) |value| self.alloc.free(value);
        self.alloc.free(self.session_id);
        self.alloc.free(self.prompt);
        self.alloc.free(self.workspace_root);
        if (self.home_dir) |value| self.alloc.free(value);
        self.alloc.free(self.model);
        secret.zeroAndFree(self.alloc, self.api_key);
        if (self.account_id) |value| self.alloc.free(value);
        if (self.team) |value| self.alloc.free(value);
        self.* = undefined;
    }
};

pub const Runtime = struct {
    alloc: ?Allocator = null,
    config: Config = .{},
    generation: u64 = 1,
    attempted_session_ids: std.ArrayList([]u8) = .empty,
    tasks: std.ArrayList(*Task) = .empty,

    pub fn configure(self: *Runtime, alloc: Allocator, config: Config) void {
        std.debug.assert(self.alloc == null);
        self.alloc = alloc;
        self.config = config;
    }

    pub fn prepareAdmission(
        self: *Runtime,
        input: AdmissionInput,
    ) !?PreparedAdmission {
        const alloc = self.alloc orelse return null;
        const provider_config = self.config.provider(input.provider_id);
        const model = provider_config.model orelse return null;
        if (input.session_id.len == 0 or input.prompt.len == 0 or input.credential.secret.len == 0) return null;
        if (!model_provider.authorizesCredential(input.provider_id, input.credential.source)) return null;
        for (self.attempted_session_ids.items) |attempted| {
            if (std.mem.eql(u8, attempted, input.session_id)) return null;
        }

        var prepared = PreparedAdmission{
            .alloc = alloc,
            .generation = self.generation,
            .timeout_ms = self.config.timeout_ms,
            .provider = input.provider,
            .effort = provider_config.effort,
            .credential_source = input.credential.source,
        };
        errdefer prepared.deinit();
        prepared.session_id = try alloc.dupe(u8, input.session_id);
        prepared.prompt = try alloc.dupe(u8, input.prompt);
        prepared.workspace_root = try alloc.dupe(u8, input.workspace_root);
        prepared.home_dir = if (input.home_dir) |value| try alloc.dupe(u8, value) else null;
        prepared.model = try alloc.dupe(u8, model);
        prepared.api_key = try alloc.dupe(u8, input.credential.secret);
        prepared.account_id = if (input.credential.account_id) |value| try alloc.dupe(u8, value) else null;
        prepared.team = if (input.credential.tenant) |value| try alloc.dupe(u8, value) else null;
        return prepared;
    }

    /// Consumes a prepared admission after the main worker queue owns its
    /// prompt. Failure is intentionally quiet and never rolls that admission
    /// back or delays the agent worker.
    pub fn admit(self: *Runtime, prepared: *PreparedAdmission) void {
        const alloc = self.alloc orelse {
            prepared.deinit();
            return;
        };
        const attempted = alloc.dupe(u8, prepared.session_id) catch {
            prepared.deinit();
            return;
        };
        self.attempted_session_ids.append(alloc, attempted) catch {
            alloc.free(attempted);
            prepared.deinit();
            return;
        };

        const task = alloc.create(Task) catch {
            prepared.deinit();
            return;
        };
        task.* = Task.fromPrepared(prepared);
        self.tasks.ensureUnusedCapacity(alloc, 1) catch {
            task.deinit();
            alloc.destroy(task);
            return;
        };
        const thread = std.Thread.spawn(.{}, Task.run, .{task}) catch {
            task.deinit();
            alloc.destroy(task);
            return;
        };
        task.thread = thread;
        self.tasks.appendAssumeCapacity(task);
    }

    /// Invalidates all in-flight results. Already-running provider calls are
    /// cancelled cooperatively but retained until they can be joined.
    pub fn invalidate(self: *Runtime) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        for (self.tasks.items) |task| task.cancel();
    }

    pub fn collect(
        self: *Runtime,
        active_session_id: ?[]const u8,
    ) ?CompletedName {
        const alloc = self.alloc orelse return null;
        const now_ns = io_mod.nanoTimestamp();
        var index: usize = 0;
        while (index < self.tasks.items.len) {
            const task = self.tasks.items[index];
            if (now_ns >= task.deadline_ns) task.cancel();
            if (!task.done.load(.seq_cst)) {
                index += 1;
                continue;
            }

            task.thread.?.join();
            task.thread = null;
            const current = active_session_id != null and
                std.mem.eql(u8, active_session_id.?, task.session_id) and
                task.generation == self.generation and
                !task.cancel_flag.load(.seq_cst);
            const title = if (current) task.title else null;
            if (title != null) task.title = null;
            const session_id = if (title != null)
                alloc.dupe(u8, task.session_id) catch null
            else
                null;
            const removed = self.tasks.swapRemove(index);
            removed.deinit();
            alloc.destroy(removed);
            if (title) |owned_title| {
                if (session_id) |owned_id| {
                    return .{
                        .alloc = alloc,
                        .session_id = owned_id,
                        .title = owned_title,
                    };
                }
                alloc.free(owned_title);
            }
        }
        return null;
    }

    pub fn requestStop(self: *Runtime) void {
        self.invalidate();
    }

    pub fn deinit(self: *Runtime) void {
        const alloc = self.alloc orelse return;
        self.requestStop();
        for (self.tasks.items) |task| {
            if (task.thread) |thread| thread.join();
            task.deinit();
            alloc.destroy(task);
        }
        self.tasks.deinit(alloc);
        for (self.attempted_session_ids.items) |session_id| alloc.free(session_id);
        self.attempted_session_ids.deinit(alloc);
        self.config.deinit(alloc);
        self.* = .{};
    }
};

fn inferTitle(task: *Task) !?[]u8 {
    if (task.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const excerpt = try buildExcerpt(
        task.alloc,
        task.prompt,
        task.workspace_root,
        task.home_dir,
    );
    defer task.alloc.free(excerpt);
    if (excerpt.len == 0 or task.cancel_flag.load(.seq_cst)) return null;

    var attempt: usize = 0;
    while (attempt < naming_attempts) : (attempt += 1) {
        if (task.cancel_flag.load(.seq_cst)) return error.Cancelled;
        const remaining_ms = task.remainingMs();
        if (remaining_ms == 0) return null;
        if (try requestTitle(task, excerpt, remaining_ms)) |title| return title;
    }
    return null;
}

/// One bounded provider request, normalized. A refused, empty, or
/// unsluggable answer is null so the caller may ask again; cancellation and
/// transport faults stay errors and end the task.
fn requestTitle(task: *Task, excerpt: []const u8, timeout_ms: u64) !?[]u8 {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = naming_instruction },
        .{ .role = .user, .content = excerpt },
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(@intCast(timeout_ms)),
    });
    var delivery = agent_stream_provider.DeliveryCertainty.init();
    var evidence: agent_stream_provider.AttemptEvidence = .{};
    var admission = NamingAdmission{ .evidence = &evidence };
    task.captured_title.store(false, .seq_cst);
    task.attempt_cancel.store(task.cancel_flag.load(.seq_cst), .seq_cst);
    var capture = TitleCapture{ .task = task };
    var result = task.provider.stream(task.alloc, .{
        .credential = .{
            .secret = task.api_key,
            .source = task.credential_source,
            .account_id = task.account_id,
            .tenant = task.team,
        },
        .session_id = null,
        .model = task.model,
        .retry_count = 1,
        .messages = &messages,
        .tools = .{},
        .tool_choice = .none,
        .vision_mode = .unavailable,
        .provider_options = .{ .reasoning = task.effort },
        .max_output_tokens = 64,
        .budget = .{ .deadline = deadline, .cancel_flag = &task.attempt_cancel },
        .trace_ctx = .{},
        .content_capture_limit = capture_max_bytes,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &capture, .emit_fn = TitleCapture.emit },
        .admission = .{ .context = &admission, .admit_fn = NamingAdmission.admit },
        .cancel_flag = &task.attempt_cancel,
        .provider_attempt_owner = .transport,
    }) catch |err| {
        if (task.cancel_flag.load(.seq_cst)) return error.Cancelled;
        // A title already settled outlives a later transport fault, because
        // the captured bytes are the whole answer a slug needs.
        if (task.captured_title.load(.seq_cst)) {
            return try slugifyTitle(task.alloc, capture.captured());
        }
        return err;
    };
    defer result.deinit(task.alloc);
    if (task.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (task.captured_title.load(.seq_cst)) {
        return try slugifyTitle(task.alloc, capture.captured());
    }
    const content = switch (result) {
        .completed => |completed| completed.completion.content orelse return null,
        .failed => return null,
    };
    return try slugifyTitle(task.alloc, content);
}

const NamingAdmission = struct {
    evidence: *agent_stream_provider.AttemptEvidence,

    fn admit(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.evidence.provider_admitted) return error.ProviderAdmissionRepeated;
        self.evidence.provider_admitted = true;
    }
};

/// Keeps the opening bytes of one naming stream and stops the provider as
/// soon as a slug can be built from them. The Codex endpoint refuses the
/// Responses API output bound, so stopping the stream is the only thing that
/// keeps a naming answer short.
const TitleCapture = struct {
    task: *Task,
    buffer: [capture_max_bytes]u8 = undefined,
    len: usize = 0,

    fn captured(self: *const TitleCapture) []const u8 {
        return self.buffer[0..self.len];
    }

    fn emit(raw: *anyopaque, event: agent_stream_provider.Event) void {
        const self: *TitleCapture = @ptrCast(@alignCast(raw));
        const delta = switch (event) {
            .content_delta => |text| text,
            else => return,
        };
        // A settled title is frozen: later deltas are read and dropped so the
        // stream can finish without changing the answer already captured.
        if (self.task.captured_title.load(.seq_cst)) return;
        // Each appended run is cut on a codepoint boundary, so the buffer
        // stays valid UTF-8 for the slug.
        const room = self.buffer.len - self.len;
        const kept = text_utils.utf8PrefixByBytes(delta, @min(room, delta.len));
        @memcpy(self.buffer[self.len..][0..kept.len], kept);
        self.len += kept.len;
        // Anything the buffer could not take is already more than a slug
        // needs, so a dropped byte settles the title as surely as a full
        // buffer or a finished first line. The stream is left to finish on
        // its own: the endpoint refuses a Responses API output bound, and
        // cancelling the read stops neither the generation nor its billing.
        const overflowed = kept.len < delta.len or self.len == self.buffer.len;
        if (!overflowed and !firstLineComplete(self.captured())) return;
        self.task.captured_title.store(true, .seq_cst);
    }
};

/// True once a line break follows text, because the slug only ever uses the
/// first non-empty line.
fn firstLineComplete(text: []const u8) bool {
    var seen_text = false;
    for (text) |byte| {
        if (byte == '\n') {
            if (seen_text) return true;
            continue;
        }
        if (!std.ascii.isWhitespace(byte)) seen_text = true;
    }
    return false;
}

pub fn buildExcerpt(
    alloc: Allocator,
    prompt: []const u8,
    workspace_root: []const u8,
    home_dir: ?[]const u8,
) ![]u8 {
    const stripped = try stripLeadingSlashCommand(alloc, prompt);
    defer alloc.free(stripped);
    if (!std.unicode.utf8ValidateSlice(stripped)) return alloc.dupe(u8, "");

    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(alloc);
    var cursor: usize = 0;
    while (cursor < stripped.len and expanded.items.len < excerpt_max_bytes) {
        const at = findMentionStart(stripped, cursor) orelse {
            try expanded.appendSlice(alloc, stripped[cursor..]);
            break;
        };
        try expanded.appendSlice(alloc, stripped[cursor..at]);
        var end = at + 1;
        while (end < stripped.len and isMentionPathByte(stripped[end])) end += 1;
        const mention = stripped[at + 1 .. end];
        if (readMention(alloc, mention, workspace_root, home_dir)) |content| {
            defer alloc.free(content);
            try expanded.appendSlice(alloc, content);
        } else |_| {
            try expanded.appendSlice(alloc, stripped[at..end]);
        }
        cursor = end;
    }
    const trimmed = std.mem.trim(u8, expanded.items, " \t\r\n");
    const bounded = text_utils.utf8PrefixByBytes(trimmed, excerpt_max_bytes);
    return alloc.dupe(u8, bounded);
}

fn stripLeadingSlashCommand(alloc: Allocator, prompt: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return alloc.dupe(u8, trimmed);

    var command_end: usize = 1;
    while (command_end < trimmed.len and !std.ascii.isWhitespace(trimmed[command_end])) {
        command_end += 1;
    }
    const command = trimmed[1..command_end];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var cursor = command_end;
    var separator: []const u8 = "";
    while (cursor < trimmed.len) {
        const separator_start = cursor;
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) cursor += 1;
        separator = trimmed[separator_start..cursor];
        const token_start = cursor;
        while (cursor < trimmed.len and !std.ascii.isWhitespace(trimmed[cursor])) cursor += 1;
        if (token_start == cursor) break;
        const token = trimmed[token_start..cursor];
        if (isLongFlagToken(token)) continue;
        if (out.items.len > 0) {
            try out.appendSlice(alloc, if (separator.len > 0) separator else " ");
        }
        try out.appendSlice(alloc, token);
    }
    if (out.items.len == 0) return alloc.dupe(u8, command);
    return out.toOwnedSlice(alloc);
}

fn isLongFlagToken(token: []const u8) bool {
    return token.len > 2 and token[0] == '-' and token[1] == '-' and
        std.ascii.isAlphanumeric(token[2]);
}

fn findMentionStart(text: []const u8, start: usize) ?usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (text[index] != '@') continue;
        if (index > 0 and !std.ascii.isWhitespace(text[index - 1])) continue;
        if (index + 1 >= text.len or !isMentionPathByte(text[index + 1])) continue;
        return index;
    }
    return null;
}

fn isMentionPathByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '.', '_', '~', '/', '-' => true,
        else => false,
    };
}

fn readMention(
    alloc: Allocator,
    mention: []const u8,
    workspace_root: []const u8,
    home_dir: ?[]const u8,
) ![]u8 {
    const expanded = if (std.mem.eql(u8, mention, "~")) blk: {
        const home = home_dir orelse return error.UnresolvedMention;
        break :blk try alloc.dupe(u8, home);
    } else if (std.mem.startsWith(u8, mention, "~/")) blk: {
        const home = home_dir orelse return error.UnresolvedMention;
        break :blk try std.fs.path.resolve(alloc, &.{ home, mention[2..] });
    } else if (std.mem.startsWith(u8, mention, "~")) {
        return error.UnresolvedMention;
    } else if (std.fs.path.isAbsolute(mention))
        try std.fs.path.resolve(alloc, &.{mention})
    else
        try std.fs.path.resolve(alloc, &.{ workspace_root, mention });
    defer alloc.free(expanded);

    var file = io_mod.openExistingReadOnlyRegularFile(
        std.Io.Dir.cwd(),
        expanded,
        .follow,
    ) catch return error.UnresolvedMention;
    defer file.close(io_mod.getIo());
    const buffer = try alloc.alloc(u8, mentioned_file_max_bytes + 1);
    defer alloc.free(buffer);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &read_buffer);
    var total: usize = 0;
    while (total < buffer.len) {
        const count = reader.interface.readSliceShort(buffer[total..]) catch
            return error.UnresolvedMention;
        if (count == 0) break;
        total += count;
    }
    var retained = @min(total, mentioned_file_max_bytes);
    while (retained > 0 and retained < total and
        (buffer[retained] & 0b1100_0000) == 0b1000_0000)
    {
        retained -= 1;
    }
    const content = buffer[0..retained];
    if (!text_utils.isModelSafeText(content)) return error.UnresolvedMention;
    return alloc.dupe(u8, content);
}

/// Normalizes one completion into a `[a-z0-9-]+` slug, or null when nothing
/// survives. The shape is the one agentsurface's `slugify` established:
/// ASCII only, lowercase, every other run collapsed to a single hyphen,
/// bounded and then re-trimmed so a cut never leaves a trailing separator.
/// Fx carries no Unicode normalizer, so an accented letter is dropped where
/// agentsurface's NFKD pass folds it to its ASCII base.
///
/// The first non-empty line and the surrounding quotes come off first. That
/// is hygiene agentsurface does not need and never changes a well-behaved
/// one-line answer, but it keeps a chatty model's second line out of the slug.
pub fn slugifyTitle(alloc: Allocator, raw: []const u8) !?[]u8 {
    if (!std.unicode.utf8ValidateSlice(raw)) return null;
    var line_it = std.mem.splitScalar(u8, raw, '\n');
    var candidate: ?[]const u8 = null;
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            candidate = trimmed;
            break;
        }
    }
    var text = candidate orelse return null;
    if (text.len >= 2 and ((text[0] == '"' and text[text.len - 1] == '"') or
        (text[0] == '\'' and text[text.len - 1] == '\'') or
        (text[0] == '`' and text[text.len - 1] == '`')))
    {
        text = std.mem.trim(u8, text[1 .. text.len - 1], " \t\r");
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var pending_separator = false;
    for (text) |byte| {
        // A continuation byte is never ASCII, so dropping the high half by
        // byte can not split a sequence the validation above accepted.
        if (byte >= 0x80) continue;
        if (!std.ascii.isAlphanumeric(byte)) {
            pending_separator = true;
            continue;
        }
        if (pending_separator and out.items.len > 0) try out.append(alloc, '-');
        pending_separator = false;
        try out.append(alloc, std.ascii.toLower(byte));
    }
    if (out.items.len > generated_title_max_bytes) {
        out.shrinkRetainingCapacity(generated_title_max_bytes);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(alloc);
}

test "session naming resolves the Codex default and skips other providers" {
    var settings = Settings{};
    var config = try resolveConfig(std.testing.allocator, &settings);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(default_codex_model, config.codex.model.?);
    try std.testing.expect(config.gateway.model == null);
    try std.testing.expect(config.grok.model == null);
    try std.testing.expect(config.codex.effort.eql(default_effort));
    try std.testing.expectEqual(default_timeout_ms, config.timeout_ms);
}

test "session naming explicit null disables the Codex default" {
    var settings = Settings{ .codex = .{ .specified = true } };
    var config = try resolveConfig(std.testing.allocator, &settings);
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(config.codex.model == null);
}

test "slash command and flags are removed before mention expansion and truncation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io_mod.getIo(), "workspace", .default_dir);
    var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/plan.md", .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "release plan " ++ ("x" ** 2000));

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const excerpt = try buildExcerpt(
        alloc,
        "/collab --model=large @plan.md implement this",
        workspace,
        null,
    );
    defer alloc.free(excerpt);

    try std.testing.expectEqual(excerpt_max_bytes, excerpt.len);
    try std.testing.expect(std.mem.startsWith(u8, excerpt, "release plan "));
    try std.testing.expect(std.mem.find(u8, excerpt, "/collab") == null);
    try std.testing.expect(std.mem.find(u8, excerpt, "--model") == null);
    try std.testing.expect(std.mem.find(u8, excerpt, "@plan.md") == null);
}

test "unresolved mentions stay literal and email addresses are not mentions" {
    const alloc = std.testing.allocator;
    const excerpt = try buildExcerpt(
        alloc,
        "review @missing.md and mail me@example.com",
        "/definitely/missing/workspace",
        null,
    );
    defer alloc.free(excerpt);
    try std.testing.expectEqualStrings(
        "review @missing.md and mail me@example.com",
        excerpt,
    );
}

test "generated titles slug to lowercase hyphens, bounded and re-trimmed" {
    const alloc = std.testing.allocator;
    const title = (try slugifyTitle(
        alloc,
        "  \"Plan \x07release \xe2\x80\xaeacross every deployment environment with careful verification\"\nignored",
    )).?;
    defer alloc.free(title);
    try std.testing.expectEqual(generated_title_max_bytes, title.len);
    try std.testing.expectEqualStrings(
        "plan-release-across-every-deployment-environment-with-careful-ve",
        title,
    );
}

test "a slug keeps no separator at either end and never runs two together" {
    const alloc = std.testing.allocator;
    const title = (try slugifyTitle(alloc, "  ---Fix   the  TRAY --- width---  ")).?;
    defer alloc.free(title);
    try std.testing.expectEqualStrings("fix-the-tray-width", title);
}

test "a completion with nothing sluggable is null so the caller may retry" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try slugifyTitle(alloc, "  \n \xe2\x80\xa6 \n")) == null);
    try std.testing.expect((try slugifyTitle(alloc, "")) == null);
}

/// Emits its chunks in order and reports whether the naming task stopped it.
const TestChattyProvider = struct {
    chunks: []const []const u8,
    emitted: usize = 0,
    stopped: std.atomic.Value(bool) = .init(false),

    fn provider(self: *@This()) agent_stream_provider.Provider {
        return .{
            .context = self,
            .stream_fn = stream,
        };
    }

    fn stream(
        raw: ?*anyopaque,
        _: Allocator,
        request: agent_stream_provider.ModelRequest,
    ) anyerror!agent_stream_provider.Result {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try request.admission.admit();
        for (self.chunks) |chunk| {
            if (request.cancel_flag.load(.seq_cst)) break;
            request.events.emit(.{ .content_delta = chunk });
            self.emitted += 1;
        }
        if (request.cancel_flag.load(.seq_cst)) {
            self.stopped.store(true, .seq_cst);
            return error.Cancelled;
        }
        return .{ .completed = .{
            .completion = .{ .content = "a whole answer the task must never need" },
            .usage = .{ .immediate = null },
        } };
    }
};

fn runOneNaming(
    runtime: *Runtime,
    provider: agent_stream_provider.Provider,
    session_id: []const u8,
) !?CompletedName {
    var prepared = (try runtime.prepareAdmission(testAdmission(provider, session_id))).?;
    defer prepared.deinit();
    runtime.admit(&prepared);
    var spins: usize = 0;
    while (spins < 5_000) : (spins += 1) {
        if (runtime.collect(session_id)) |completed| return completed;
        if (runtime.tasks.items.len == 0) return null;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return null;
}

test "a settled first line freezes the title and lets the stream finish" {
    const alloc = std.testing.allocator;
    var settings = Settings{};
    var config = try resolveConfig(alloc, &settings);
    var runtime = Runtime{};
    runtime.configure(alloc, config);
    config = .{};
    defer runtime.deinit();

    var fake = TestChattyProvider{ .chunks = &.{
        "Fix the tray",
        " width\n",
        "and every further word the provider would have billed",
    } };
    var completed = (try runOneNaming(&runtime, fake.provider(), "session-a")).?;
    defer completed.deinit();

    try std.testing.expectEqualStrings("fix-the-tray-width", completed.title);
    // The stream is never cancelled, so every chunk is delivered and the
    // provider's own completion is reached; the frozen capture still wins.
    try std.testing.expect(!fake.stopped.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 3), fake.emitted);
}

test "a stream without a line break freezes the title at the capture bound" {
    const alloc = std.testing.allocator;
    var settings = Settings{};
    var config = try resolveConfig(alloc, &settings);
    var runtime = Runtime{};
    runtime.configure(alloc, config);
    config = .{};
    defer runtime.deinit();

    // The multibyte codepoint straddles the bound, so the kept bytes must be
    // cut before it for the slug to survive.
    var fake = TestChattyProvider{ .chunks = &.{
        ("x" ** (capture_max_bytes - 1)) ++ "\u{e9}" ++ " trailing prose",
        "and every further word the provider would have billed",
    } };
    var completed = (try runOneNaming(&runtime, fake.provider(), "session-b")).?;
    defer completed.deinit();

    try std.testing.expectEqual(generated_title_max_bytes, completed.title.len);
    try std.testing.expectEqualStrings("x" ** generated_title_max_bytes, completed.title);
    try std.testing.expect(!fake.stopped.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fake.emitted);
}

const TestNamingProvider = struct {
    started: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn provider(self: *@This()) agent_stream_provider.Provider {
        return .{
            .context = self,
            .stream_fn = stream,
        };
    }

    fn stream(
        raw: ?*anyopaque,
        _: Allocator,
        request: agent_stream_provider.ModelRequest,
    ) anyerror!agent_stream_provider.Result {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (request.tool_choice != .none or
            request.tools.advertised_names.len != 0 or
            request.tools.advertised_functions.len != 0 or
            request.tools.additional_functions.len != 0 or
            request.tools.selected_dynamic.len != 0)
        {
            return error.UnexpectedNamingTools;
        }
        try request.admission.admit();
        self.started.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) {
            if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        return .{ .completed = .{
            .completion = .{ .content = "Native generated title" },
            .usage = .{ .immediate = null },
        } };
    }
};

fn testAdmission(provider: agent_stream_provider.Provider, session_id: []const u8) AdmissionInput {
    return .{
        .session_id = session_id,
        .prompt = "name this session",
        .workspace_root = "/tmp/workspace",
        .home_dir = "/tmp/home",
        .provider_id = .codex,
        .provider = provider,
        .credential = .{
            .secret = "test-secret",
            .source = .chatgpt_subscription,
            .account_id = "account",
        },
    };
}

test "session naming rejects a credential from a different active provider" {
    const alloc = std.testing.allocator;
    var settings = Settings{};
    var config = try resolveConfig(alloc, &settings);
    var runtime = Runtime{};
    runtime.configure(alloc, config);
    config = .{};
    defer runtime.deinit();

    var input = testAdmission(agent_stream_provider.unavailable_provider, "session-a");
    input.credential.source = .ai_gateway_api_key;
    try std.testing.expect((try runtime.prepareAdmission(input)) == null);
}

test "invalidated session naming work cannot publish into a replacement session" {
    const alloc = std.testing.allocator;
    var settings = Settings{};
    var config = try resolveConfig(alloc, &settings);
    var runtime = Runtime{};
    runtime.configure(alloc, config);
    config = .{};
    defer runtime.deinit();

    var fake = TestNamingProvider{};
    var prepared = (try runtime.prepareAdmission(testAdmission(fake.provider(), "session-a"))).?;
    defer prepared.deinit();
    runtime.admit(&prepared);

    var spins: usize = 0;
    while (!fake.started.load(.seq_cst) and spins < 2_000) : (spins += 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(fake.started.load(.seq_cst));

    runtime.invalidate();
    fake.release.store(true, .seq_cst);
    spins = 0;
    while (runtime.tasks.items.len > 0 and spins < 2_000) : (spins += 1) {
        try std.testing.expect(runtime.collect("session-b") == null);
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 0), runtime.tasks.items.len);
}
