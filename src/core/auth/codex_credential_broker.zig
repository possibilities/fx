//! Fx is the sole Codex subscription authority for the process that launched
//! it. A host that passes `--codex-credential-fd <n>` hands Fx one already
//! connected local stream socket; Fx serves bounded runtime leases on it and
//! never returns a refresh token, a serialized session, or any store
//! representation. The broker is deliberately independent of the ADE event
//! feed and of semantic work control: it is an authority channel, not
//! telemetry and not a command surface.
const std = @import("std");
const builtin = @import("builtin");
const auth_runtime = @import("auth_runtime.zig");
const credential_authority = @import("credential_authority.zig");
const credentials = @import("credentials.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema: u8 = 1;

/// The borrowed-credential selector. A borrowed profile is read-only by
/// contract, so the broker refuses rather than leasing authority it may never
/// rotate. The name is read here rather than imported so this carry does not
/// depend on the head that implements borrowing.
pub const read_only_home_env = "FX_AUTH_READ_ONLY_HOME";

const max_frame_bytes: usize = 64 * 1024;
/// A frame that has begun must finish inside this window. The idle wait for
/// the next request is deliberately unbounded: the channel is persistent.
const default_frame_deadline_ms: i64 = 5_000;
/// A response must remain usable after it is delivered. Reserve the consumer's
/// five-minute lease plus its own request timeout and transport grace, so a
/// lease can never cross that floor while it is still in flight.
const response_minimum_validity_seconds: u64 = 313;
const max_minimum_validity_seconds: u64 = 86_400;
const oauth_request_timeout_ms: i64 = 8_000;
const token_fingerprint_domain = "fx:codex-credential-broker:bearer-fingerprint:v1\x00";
const nonce_random_bytes: usize = 24;
const nonce_len: usize = nonce_random_bytes * 2;
const max_request_id_len: usize = 20;

pub const StartError = error{
    CodexCredentialBrokerAlreadyStarted,
    CodexCredentialBrokerHostManagedAuth,
    CodexCredentialBrokerBorrowedAuth,
    CodexCredentialBrokerCredentialUnavailable,
    CodexCredentialFdUnavailable,
    CodexCredentialFdNotLocalStream,
    CodexCredentialFdNotConnected,
    CodexCredentialPeerUnavailable,
    CodexCredentialPeerRejected,
} || Allocator.Error || std.Thread.SpawnError;

/// Owns the validated inherited descriptor from launch parsing until the
/// hosting surface transfers it into a `Runtime`.
pub const Activation = struct {
    fd: ?std.c.fd_t = null,

    pub fn prepare(configured_fd: ?u8) !Activation {
        const configured = configured_fd orelse return .{};
        if (configured < 3) return error.CodexCredentialFdUnavailable;
        const fd: std.c.fd_t = @intCast(configured);
        return prepareOnFd(fd);
    }

    fn prepareOnFd(fd: std.c.fd_t) !Activation {
        errdefer closeSocket(fd);
        // Close-on-exec is the first operation on the inherited capability:
        // launch bootstrap can spawn a child before the broker thread exists,
        // and no descendant may inherit this channel.
        try setCloseOnExec(fd);
        try setBlocking(fd);
        try validateConnectedLocalStream(fd);
        try suppressSigPipe(fd);
        const peer = readPeerIdentity(fd) catch return error.CodexCredentialPeerUnavailable;
        if (peer.uid != std.c.getuid()) return error.CodexCredentialPeerRejected;
        return .{ .fd = fd };
    }

    pub fn active(self: Activation) bool {
        return self.fd != null;
    }

    pub fn deinit(self: *Activation) void {
        if (self.fd) |fd| closeSocket(fd);
        self.* = .{};
    }

    fn take(self: *Activation) ?std.c.fd_t {
        const fd = self.fd;
        self.fd = null;
        return fd;
    }
};

pub const PeerIdentity = struct {
    uid: std.c.uid_t,
    pid: std.c.pid_t,
};

const PeerProbe = struct {
    context: ?*anyopaque = null,
    read_fn: *const fn (?*anyopaque, std.c.fd_t) anyerror!PeerIdentity,

    fn read(self: PeerProbe, fd: std.c.fd_t) !PeerIdentity {
        return self.read_fn(self.context, fd);
    }
};

fn socketPeerProbe(_: ?*anyopaque, fd: std.c.fd_t) anyerror!PeerIdentity {
    return readPeerIdentity(fd);
}

const default_peer_probe = PeerProbe{ .read_fn = socketPeerProbe };

const Lease = struct {
    access_token: []u8,
    account_id: []u8,
    refresh_deadline_ms: i64,

    fn deinit(self: *Lease, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.account_id);
        self.* = undefined;
    }
};

const LoadMode = enum {
    stored,
    force,
};

const LoadFn = *const fn (?*anyopaque, Allocator, LoadMode, []const u8) anyerror!?Lease;

const CredentialProvider = struct {
    context: ?*anyopaque,
    load_fn: LoadFn,

    fn load(
        self: CredentialProvider,
        alloc: Allocator,
        mode: LoadMode,
        expected_account_id: []const u8,
    ) !?Lease {
        return self.load_fn(self.context, alloc, mode, expected_account_id);
    }
};

const Clock = struct {
    context: ?*anyopaque = null,
    now_fn: *const fn (?*anyopaque) i64 = realNow,

    fn now(self: Clock) i64 {
        return self.now_fn(self.context);
    }
};

fn realNow(_: ?*anyopaque) i64 {
    return io_mod.milliTimestamp();
}

const Request = union(enum) {
    resolve: struct {
        minimum_validity_seconds: u64,
    },
    refresh: struct {
        account_id: []const u8,
        prior_generation: u64,
    },
};

const DecodedRequest = struct {
    request_id: []const u8,
    nonce: []const u8,
    request: Request,
};

const HandleResult = union(enum) {
    response: []u8,
    /// The frame is not a request this channel may answer. The caller ends the
    /// channel: a peer that cannot frame a request cannot be corrected.
    close,
    /// One correlated refusal, then the channel ends. Admission failures are
    /// terminal for the descriptor, not a retryable condition.
    refuse: []u8,
};

const ErrorResponse = struct {
    code: []const u8,
    message: []const u8,
};

const unauthorized_response = ErrorResponse{
    .code = "unauthorized",
    .message = "The credential channel is bound to another peer.",
};

const Service = struct {
    alloc: Allocator,
    provider: CredentialProvider,
    clock: Clock,
    expected_uid: std.c.uid_t,
    nonce: [nonce_len]u8,
    pinned_account_id: []const u8,
    pinned_identity: credential_authority.Identity,
    pinned_pid: ?std.c.pid_t = null,
    fingerprint: ?[Sha256.digest_length]u8 = null,
    generation: u64 = 0,

    fn admit(self: *Service, peer: PeerIdentity, nonce: []const u8) bool {
        // The socket's own credentials come first: a descriptor that reached a
        // process running as somebody else is refused before anything reads a
        // credential store.
        if (peer.uid != self.expected_uid) {
            debug_trace.logf("auth", "codex credential broker refused stage=peer_uid", .{});
            return false;
        }
        if (self.pinned_pid) |pinned| {
            if (pinned != peer.pid) {
                debug_trace.logf("auth", "codex credential broker refused stage=peer_pid", .{});
                return false;
            }
        }
        if (nonce.len != self.nonce.len or
            !std.crypto.timing_safe.eql([nonce_len]u8, self.nonce, nonce[0..nonce_len].*))
        {
            debug_trace.logf("auth", "codex credential broker refused stage=nonce", .{});
            return false;
        }
        self.pinned_pid = peer.pid;
        return true;
    }

    fn handle(
        self: *Service,
        response_alloc: Allocator,
        payload: []const u8,
        peer: PeerIdentity,
    ) !HandleResult {
        var parse_allocator = secret.ZeroOnFreeAllocator.init(response_alloc);
        var parsed = std.json.parseFromSlice(std.json.Value, parse_allocator.allocator(), payload, .{
            .duplicate_field_behavior = .@"error",
        }) catch return .close;
        defer parsed.deinit();

        const request_id = validRequestId(parsed.value) orelse return .close;
        const decoded = decodeRequest(parsed.value) catch |err| switch (err) {
            error.InvalidParams => return .{ .response = try writeErrorResponse(response_alloc, request_id, .{
                .code = "invalid_params",
                .message = "The credential request parameters are invalid.",
            }) },
            else => return .close,
        };

        if (!self.admit(peer, decoded.nonce)) {
            return .{ .refuse = try writeErrorResponse(
                response_alloc,
                request_id,
                unauthorized_response,
            ) };
        }

        switch (decoded.request) {
            .resolve => |request| {
                const seconds = @max(
                    request.minimum_validity_seconds,
                    response_minimum_validity_seconds,
                );
                const required_deadline_ms = requiredDeadline(self.clock.now(), seconds) catch {
                    return .{ .response = try writeErrorResponse(response_alloc, request_id, .{
                        .code = "invalid_params",
                        .message = "minimum_validity_seconds is out of range.",
                    }) };
                };
                var lease = self.resolve(required_deadline_ms) catch |err| {
                    return .{ .response = try writeOperationError(response_alloc, request_id, err) };
                };
                defer lease.deinit(self.alloc);
                return .{ .response = try writeSuccessResponse(
                    response_alloc,
                    request_id,
                    lease,
                    self.generation,
                ) };
            },
            .refresh => |request| {
                if (!std.mem.eql(u8, request.account_id, self.pinned_account_id)) {
                    return .{ .response = try writeErrorResponse(response_alloc, request_id, .{
                        .code = "account_mismatch",
                        .message = "The credential request does not match the pinned Codex account.",
                    }) };
                }
                var lease = self.refresh(request.prior_generation) catch |err| {
                    return .{ .response = try writeOperationError(response_alloc, request_id, err) };
                };
                defer lease.deinit(self.alloc);
                return .{ .response = try writeSuccessResponse(
                    response_alloc,
                    request_id,
                    lease,
                    self.generation,
                ) };
            },
        }
    }

    fn resolve(self: *Service, required_deadline_ms: i64) !Lease {
        var lease = try self.observe();
        if (lease.refresh_deadline_ms >= required_deadline_ms) return lease;
        lease.deinit(self.alloc);

        lease = try self.forceRefresh();
        if (lease.refresh_deadline_ms < required_deadline_ms) {
            lease.deinit(self.alloc);
            return error.InsufficientValidity;
        }
        return lease;
    }

    fn refresh(self: *Service, prior_generation: u64) !Lease {
        if (prior_generation > self.generation) return error.FutureGeneration;
        const required_deadline_ms = requiredDeadline(
            self.clock.now(),
            response_minimum_validity_seconds,
        ) catch return error.InvalidClock;
        var lease = try self.observe();
        // An older generation asked for a rotation that already happened. It
        // receives the newer lease unchanged rather than rotating twice.
        if (prior_generation < self.generation and
            lease.refresh_deadline_ms >= required_deadline_ms)
        {
            return lease;
        }

        lease.deinit(self.alloc);
        lease = try self.forceRefresh();
        if (lease.refresh_deadline_ms < required_deadline_ms) {
            lease.deinit(self.alloc);
            return error.InsufficientValidity;
        }
        return lease;
    }

    fn observe(self: *Service) !Lease {
        var lease = (try self.provider.load(
            self.alloc,
            .stored,
            self.pinned_account_id,
        )) orelse return error.CredentialUnavailable;
        errdefer lease.deinit(self.alloc);
        try self.validateAuthority(lease.account_id);

        var next_fingerprint = tokenFingerprint(lease.access_token);
        defer std.crypto.secureZero(u8, @volatileCast(next_fingerprint[0..]));
        if (self.fingerprint) |*current| {
            if (!std.mem.eql(u8, current[0..], next_fingerprint[0..])) {
                try self.advanceGeneration();
            }
        } else {
            self.generation = 1;
        }
        self.clearSecrets();
        self.fingerprint = next_fingerprint;
        return lease;
    }

    fn forceRefresh(self: *Service) !Lease {
        var lease = (try self.provider.load(
            self.alloc,
            .force,
            self.pinned_account_id,
        )) orelse return error.CredentialUnavailable;
        errdefer lease.deinit(self.alloc);
        try self.validateAuthority(lease.account_id);
        try self.advanceGeneration();
        var next_fingerprint = tokenFingerprint(lease.access_token);
        defer std.crypto.secureZero(u8, @volatileCast(next_fingerprint[0..]));
        self.clearSecrets();
        self.fingerprint = next_fingerprint;
        return lease;
    }

    fn clearSecrets(self: *Service) void {
        if (self.fingerprint) |*fingerprint| {
            std.crypto.secureZero(u8, @volatileCast(fingerprint[0..]));
        }
        self.fingerprint = null;
    }

    /// Every later load, OAuth result, and persisted rotation must still name
    /// the pinned account. The account string and its derived authority are
    /// both checked: the string is what the lease carries, and the authority is
    /// what the rest of Fx compares credentials by.
    fn validateAuthority(self: *const Service, account_id: []const u8) !void {
        if (!std.mem.eql(u8, account_id, self.pinned_account_id)) {
            return error.ChatGptAccountChanged;
        }
        const identity = credential_authority.derive(
            .chatgpt_subscription,
            account_id,
        ) orelse return error.ChatGptAccountChanged;
        if (!identity.eql(self.pinned_identity)) return error.ChatGptAccountChanged;
    }

    fn advanceGeneration(self: *Service) !void {
        if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        self.generation += 1;
    }
};

const Worker = struct {
    alloc: Allocator,
    fd: std.c.fd_t,
    peer_probe: PeerProbe,
    transport: oauth_transport.Provider,
    oauth_cancel: std.atomic.Value(bool),
    pinned_account_id: []u8,
    frame_deadline_ms: i64 = default_frame_deadline_ms,
    service: Service,

    fn deinit(self: *Worker) void {
        secret.zeroAndFree(self.alloc, self.pinned_account_id);
        self.service.clearSecrets();
        std.crypto.secureZero(u8, @volatileCast(self.service.nonce[0..]));
        self.* = undefined;
    }

    fn run(self: *Worker) void {
        defer shutdownSocket(self.fd);
        while (true) {
            const frame = readFrame(self.alloc, self.fd, self.frame_deadline_ms) catch return;
            switch (frame) {
                .eof => return,
                .payload => |payload| {
                    defer secret.zeroAndFree(self.alloc, payload);
                    const peer = self.peer_probe.read(self.fd) catch return;
                    const result = self.service.handle(self.alloc, payload, peer) catch return;
                    switch (result) {
                        .close => return,
                        .refuse => |response| {
                            defer secret.zeroAndFree(self.alloc, response);
                            writeFrame(self.fd, response, self.frame_deadline_ms) catch {};
                            return;
                        },
                        .response => |response| {
                            defer secret.zeroAndFree(self.alloc, response);
                            writeFrame(self.fd, response, self.frame_deadline_ms) catch return;
                        },
                    }
                },
            }
        }
    }
};

pub const StartDeps = struct {
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    auth_mode: credentials.AuthMode,
};

pub const Runtime = struct {
    worker: ?*Worker = null,
    thread: ?std.Thread = null,

    /// Transfers a prepared activation into a live broker. Returns false only
    /// when no descriptor was configured. Every other outcome is all-or-none:
    /// the broker is serving before this returns, or it fails the launch.
    pub fn start(
        self: *Runtime,
        alloc: Allocator,
        activation: *Activation,
        deps: StartDeps,
    ) StartError!bool {
        if (self.active()) return error.CodexCredentialBrokerAlreadyStarted;
        const fd = activation.take() orelse return false;
        errdefer closeSocket(fd);
        if (deps.auth_mode == .host_managed) {
            return error.CodexCredentialBrokerHostManagedAuth;
        }
        if (borrowedAuthorizationConfigured()) {
            return error.CodexCredentialBrokerBorrowedAuth;
        }

        var credential = (auth_runtime.prepareCredential(
            alloc,
            deps.transport,
            deps.secret_store,
            .codex,
            null,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        }) orelse return error.CodexCredentialBrokerCredentialUnavailable;
        defer credential.deinit(alloc);
        if (credential.source != .chatgpt_subscription) {
            return error.CodexCredentialBrokerCredentialUnavailable;
        }
        const account_id = credential.accountId() orelse
            return error.CodexCredentialBrokerCredentialUnavailable;
        if (!types.validCredentialAccountId(account_id)) {
            return error.CodexCredentialBrokerCredentialUnavailable;
        }
        const pinned_identity = credential_authority.derive(
            .chatgpt_subscription,
            account_id,
        ) orelse return error.CodexCredentialBrokerCredentialUnavailable;

        const owned_account_id = try alloc.dupe(u8, account_id);
        errdefer secret.zeroAndFree(alloc, owned_account_id);

        const worker = try alloc.create(Worker);
        errdefer alloc.destroy(worker);
        worker.* = .{
            .alloc = alloc,
            .fd = fd,
            .peer_probe = default_peer_probe,
            .transport = deps.transport,
            .oauth_cancel = std.atomic.Value(bool).init(false),
            .pinned_account_id = owned_account_id,
            .service = .{
                .alloc = alloc,
                .provider = undefined,
                .clock = .{},
                .expected_uid = std.c.getuid(),
                .nonce = generateNonce(),
                .pinned_account_id = owned_account_id,
                .pinned_identity = pinned_identity,
            },
        };
        worker.service.provider = .{
            .context = worker,
            .load_fn = loadProductionLease,
        };
        errdefer worker.deinit();

        // The hello frame is written before the thread exists, so a caller that
        // sees Fx started has already been handed the instance nonce.
        const hello = writeHelloFrame(alloc, &worker.service.nonce) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CodexCredentialFdUnavailable,
        };
        defer secret.zeroAndFree(alloc, hello);
        writeFrame(fd, hello, default_frame_deadline_ms) catch
            return error.CodexCredentialFdUnavailable;

        const thread = try std.Thread.spawn(.{}, Worker.run, .{worker});
        self.worker = worker;
        self.thread = thread;
        return true;
    }

    pub fn active(self: *const Runtime) bool {
        return self.worker != null;
    }

    pub fn deinit(self: *Runtime) void {
        const worker = self.worker orelse {
            self.* = .{};
            return;
        };
        worker.oauth_cancel.store(true, .seq_cst);
        // Shutdown wakes a blocked receive first. The descriptor stays
        // allocated until the worker has unwound so its number cannot be
        // reused under it.
        shutdownSocket(worker.fd);
        if (self.thread) |thread| thread.join();
        closeSocket(worker.fd);
        const alloc = worker.alloc;
        worker.deinit();
        alloc.destroy(worker);
        self.* = .{};
    }
};

pub fn borrowedAuthorizationConfigured() bool {
    const value = io_mod.getenv(read_only_home_env) orelse return false;
    return value.len > 0;
}

fn generateNonce() [nonce_len]u8 {
    var random_bytes: [nonce_random_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, @volatileCast(random_bytes[0..]));
    io_mod.getIo().random(&random_bytes);
    var nonce: [nonce_len]u8 = undefined;
    _ = std.fmt.bufPrint(&nonce, "{x}", .{&random_bytes}) catch unreachable;
    return nonce;
}

fn loadProductionLease(
    raw: ?*anyopaque,
    alloc: Allocator,
    mode: LoadMode,
    expected_account_id: []const u8,
) !?Lease {
    const worker: *Worker = @ptrCast(@alignCast(raw.?));
    var credential = (try auth_runtime.refreshCredentialForAccount(
        boundedOAuthProvider(worker),
        alloc,
        .chatgpt_subscription,
        switch (mode) {
            .stored => .if_needed,
            .force => .force,
        },
        expected_account_id,
    )) orelse return null;
    errdefer credential.deinit(alloc);

    const refresh_after_ms = credential.refresh_after_ms orelse
        return error.CredentialUnavailable;
    const account_id = credential.account_id orelse return error.CredentialUnavailable;
    const lease = Lease{
        .access_token = credential.token,
        .account_id = account_id,
        .refresh_deadline_ms = refresh_after_ms,
    };
    credential.token = &.{};
    credential.account_id = null;
    credential.deinit(alloc);
    return lease;
}

fn boundedOAuthProvider(worker: *Worker) oauth_transport.Provider {
    return .{
        .context = worker,
        .execute_fn = executeBoundedOAuthRequest,
    };
}

fn executeBoundedOAuthRequest(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: oauth_transport.Request,
) !oauth_transport.Response {
    const worker: *Worker = @ptrCast(@alignCast(raw.?));
    if (worker.oauth_cancel.load(.seq_cst)) return error.Cancelled;

    const broker_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(oauth_request_timeout_ms),
    });
    const deadline = if (request.deadline) |caller_deadline|
        if (caller_deadline.clock == broker_deadline.clock and
            std.Io.Clock.Timestamp.compare(caller_deadline, .lt, broker_deadline))
            caller_deadline
        else
            broker_deadline
    else
        broker_deadline;
    var bounded_request = request;
    bounded_request.cancel_flag = &worker.oauth_cancel;
    bounded_request.deadline = deadline;
    return worker.transport.execute(alloc, bounded_request);
}

fn validRequestId(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const request_id = value.object.get("request_id") orelse return null;
    if (request_id != .string) return null;
    if (request_id.string.len == 0) return null;
    if (request_id.string.len > max_request_id_len) return null;
    if (request_id.string.len > 1 and request_id.string[0] == '0') return null;
    for (request_id.string) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    _ = std.fmt.parseUnsigned(u64, request_id.string, 10) catch return null;
    return request_id.string;
}

fn decodeRequest(value: std.json.Value) !DecodedRequest {
    if (value != .object or value.object.count() != 5) return error.ProtocolFault;
    const schema_value = value.object.get("schema") orelse return error.ProtocolFault;
    if (schema_value != .integer or schema_value.integer != schema) return error.ProtocolFault;
    const request_id = validRequestId(value) orelse return error.ProtocolFault;
    const nonce_value = value.object.get("nonce") orelse return error.ProtocolFault;
    if (nonce_value != .string) return error.ProtocolFault;
    const method_value = value.object.get("method") orelse return error.ProtocolFault;
    if (method_value != .string) return error.ProtocolFault;
    const params = value.object.get("params") orelse return error.ProtocolFault;
    if (params != .object) return error.ProtocolFault;

    if (std.mem.eql(u8, method_value.string, "codex.credential.resolve")) {
        if (params.object.count() != 1) return error.ProtocolFault;
        const minimum = params.object.get("minimum_validity_seconds") orelse
            return error.ProtocolFault;
        const seconds = parseUnsignedInteger(minimum) catch return error.InvalidParams;
        if (seconds > max_minimum_validity_seconds) return error.InvalidParams;
        return .{
            .request_id = request_id,
            .nonce = nonce_value.string,
            .request = .{ .resolve = .{ .minimum_validity_seconds = seconds } },
        };
    }
    if (std.mem.eql(u8, method_value.string, "codex.credential.refresh")) {
        if (params.object.count() != 2) return error.ProtocolFault;
        const account = params.object.get("account_id") orelse return error.ProtocolFault;
        const generation = params.object.get("prior_generation") orelse
            return error.ProtocolFault;
        if (account != .string) return error.InvalidParams;
        const generation_value = parseUnsignedInteger(generation) catch
            return error.InvalidParams;
        if (generation_value == 0) return error.InvalidParams;
        return .{
            .request_id = request_id,
            .nonce = nonce_value.string,
            .request = .{ .refresh = .{
                .account_id = account.string,
                .prior_generation = generation_value,
            } },
        };
    }
    return error.ProtocolFault;
}

fn parseUnsignedInteger(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidParams,
        .number_string => |number| std.fmt.parseUnsigned(u64, number, 10) catch error.InvalidParams,
        else => error.InvalidParams,
    };
}

fn requiredDeadline(now_ms: i64, minimum_validity_seconds: u64) !i64 {
    if (now_ms < 0) return error.InvalidRequest;
    const now: u64 = @intCast(now_ms);
    const validity_ms = std.math.mul(u64, minimum_validity_seconds, 1000) catch
        return error.InvalidRequest;
    const deadline = std.math.add(u64, now, validity_ms) catch return error.InvalidRequest;
    if (deadline > std.math.maxInt(i64)) return error.InvalidRequest;
    return @intCast(deadline);
}

fn tokenFingerprint(access_token: []const u8) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    defer std.crypto.secureZero(u8, @volatileCast(std.mem.asBytes(&hasher)[0..]));
    hasher.update(token_fingerprint_domain);
    hasher.update(access_token);
    var fingerprint: [Sha256.digest_length]u8 = undefined;
    hasher.final(&fingerprint);
    return fingerprint;
}

fn writeHelloFrame(alloc: Allocator, nonce: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer {
        std.crypto.secureZero(u8, @volatileCast(out.writer.buffer));
        out.deinit();
    }
    try out.writer.print("{{\"schema\":{d},\"hello\":{{\"nonce\":", .{schema});
    try std.json.Stringify.value(nonce, .{}, &out.writer);
    try out.writer.writeAll("}}");
    if (out.written().len > max_frame_bytes) return error.ResponseTooLarge;
    return try alloc.dupe(u8, out.written());
}

fn writeSuccessResponse(
    alloc: Allocator,
    request_id: []const u8,
    lease: Lease,
    generation: u64,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer {
        std.crypto.secureZero(u8, @volatileCast(out.writer.buffer));
        out.deinit();
    }
    try out.writer.print("{{\"schema\":{d},\"request_id\":", .{schema});
    try std.json.Stringify.value(request_id, .{}, &out.writer);
    try out.writer.writeAll(",\"ok\":true,\"result\":{\"access_token\":");
    try std.json.Stringify.value(lease.access_token, .{}, &out.writer);
    try out.writer.writeAll(",\"account_id\":");
    try std.json.Stringify.value(lease.account_id, .{}, &out.writer);
    try out.writer.print(",\"refresh_deadline\":{d},\"generation\":{d}", .{
        @divFloor(lease.refresh_deadline_ms, 1000),
        generation,
    });
    try out.writer.writeAll("}}");
    if (out.written().len > max_frame_bytes) return error.ResponseTooLarge;
    return try alloc.dupe(u8, out.written());
}

fn writeErrorResponse(
    alloc: Allocator,
    request_id: []const u8,
    response_error: ErrorResponse,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"schema\":{d},\"request_id\":", .{schema});
    try std.json.Stringify.value(request_id, .{}, &out.writer);
    try out.writer.writeAll(",\"ok\":false,\"error\":{\"code\":");
    try std.json.Stringify.value(response_error.code, .{}, &out.writer);
    try out.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(response_error.message, .{}, &out.writer);
    try out.writer.writeAll("}}");
    if (out.written().len > max_frame_bytes) return error.ResponseTooLarge;
    return try out.toOwnedSlice();
}

fn writeOperationError(alloc: Allocator, request_id: []const u8, err: anyerror) ![]u8 {
    const response_error: ErrorResponse = switch (err) {
        error.ChatGptAccountChanged => .{
            .code = "account_changed",
            .message = "The pinned Codex account changed.",
        },
        error.CredentialUnavailable => .{
            .code = "credential_unavailable",
            .message = "The pinned Codex credential is unavailable.",
        },
        error.FutureGeneration => .{
            .code = "future_generation",
            .message = "The requested credential generation has not been issued.",
        },
        error.InsufficientValidity => .{
            .code = "insufficient_validity",
            .message = "The Codex credential cannot satisfy the requested validity.",
        },
        error.GenerationExhausted, error.InvalidClock => .{
            .code = "broker_unavailable",
            .message = "The Codex credential broker is unavailable.",
        },
        else => .{
            .code = "credential_operation_failed",
            .message = "The Codex credential operation failed.",
        },
    };
    return writeErrorResponse(alloc, request_id, response_error);
}

const ReadFrame = union(enum) {
    eof,
    payload: []u8,
};

fn readFrame(alloc: Allocator, fd: std.c.fd_t, frame_deadline_ms: i64) !ReadFrame {
    var prefix: [4]u8 = undefined;
    // The idle wait is unbounded; the frame deadline starts with its first byte.
    if (!try readExact(fd, &prefix, null, frame_deadline_ms)) return .eof;
    const deadline_ms = io_mod.milliTimestamp() + frame_deadline_ms;
    const length: usize = std.mem.readInt(u32, &prefix, .big);
    if (length == 0 or length > max_frame_bytes) return error.InvalidFrameLength;
    const payload = try alloc.alloc(u8, length);
    errdefer secret.zeroAndFree(alloc, payload);
    _ = try readExact(fd, payload, deadline_ms, frame_deadline_ms);
    return .{ .payload = payload };
}

/// Reads exactly `bytes.len`. A null deadline permits an unbounded wait before
/// the first byte only; every continuation is bounded so a stalled partial
/// frame fails instead of holding the channel open forever.
fn readExact(fd: std.c.fd_t, bytes: []u8, deadline_ms: ?i64, frame_deadline_ms: i64) !bool {
    var offset: usize = 0;
    var frame_deadline_ms_value = deadline_ms;
    while (offset < bytes.len) {
        if (frame_deadline_ms_value) |deadline| {
            try awaitReady(fd, std.c.POLL.IN, deadline);
        } else {
            try awaitReadyUnbounded(fd, std.c.POLL.IN);
        }
        const result = std.c.recv(fd, bytes[offset..].ptr, bytes.len - offset, 0);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) {
                    if (deadline_ms == null and offset == 0) return false;
                    return error.TruncatedFrame;
                }
                offset += @intCast(result);
                if (frame_deadline_ms_value == null) {
                    frame_deadline_ms_value = io_mod.milliTimestamp() + frame_deadline_ms;
                }
            },
            .INTR => continue,
            .AGAIN => continue,
            else => return error.ReadFailed,
        }
    }
    return true;
}

fn writeFrame(fd: std.c.fd_t, payload: []const u8, frame_deadline_ms: i64) !void {
    if (payload.len == 0 or payload.len > max_frame_bytes) return error.InvalidFrameLength;
    const deadline_ms = io_mod.milliTimestamp() + frame_deadline_ms;
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(payload.len), .big);
    try writeAll(fd, &prefix, deadline_ms);
    try writeAll(fd, payload, deadline_ms);
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8, deadline_ms: i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try awaitReady(fd, std.c.POLL.OUT, deadline_ms);
        // SIGPIPE never reaches the process: Linux passes MSG_NOSIGNAL and
        // macOS carries SO_NOSIGPIPE on the descriptor itself.
        const flags: u32 = if (@hasDecl(std.c.MSG, "NOSIGNAL")) std.c.MSG.NOSIGNAL else 0;
        const result = std.c.send(fd, bytes[offset..].ptr, bytes.len - offset, flags);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.WriteFailed;
                offset += @intCast(result);
            },
            .INTR => continue,
            .AGAIN => continue,
            else => return error.WriteFailed,
        }
    }
}

fn awaitReady(fd: std.c.fd_t, events: i16, deadline_ms: i64) !void {
    while (true) {
        const remaining = deadline_ms - io_mod.milliTimestamp();
        if (remaining <= 0) return error.FrameDeadlineExceeded;
        const timeout: i32 = @intCast(@min(remaining, std.math.maxInt(i32)));
        var fds = [_]std.c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const result = std.c.poll(&fds, 1, timeout);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.FrameDeadlineExceeded;
                if (fds[0].revents & (std.c.POLL.ERR | std.c.POLL.NVAL) != 0) {
                    return error.ChannelClosed;
                }
                return;
            },
            .INTR => continue,
            else => return error.ChannelClosed,
        }
    }
}

fn awaitReadyUnbounded(fd: std.c.fd_t, events: i16) !void {
    while (true) {
        var fds = [_]std.c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const result = std.c.poll(&fds, 1, -1);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) continue;
                if (fds[0].revents & (std.c.POLL.ERR | std.c.POLL.NVAL) != 0) {
                    return error.ChannelClosed;
                }
                return;
            },
            .INTR => continue,
            else => return error.ChannelClosed,
        }
    }
}

fn setCloseOnExec(fd: std.c.fd_t) !void {
    while (true) {
        const result = std.posix.system.fcntl(
            fd,
            std.posix.F.SETFD,
            @as(usize, std.posix.FD_CLOEXEC),
        );
        switch (std.posix.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.CodexCredentialFdUnavailable,
        }
    }
}

fn setBlocking(fd: std.c.fd_t) !void {
    const current_flags = while (true) {
        const result = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
        switch (std.posix.errno(result)) {
            .SUCCESS => break @as(usize, @intCast(result)),
            .INTR => continue,
            else => return error.CodexCredentialFdUnavailable,
        }
    };
    const nonblocking = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if ((current_flags & nonblocking) == 0) return;
    const blocking_flags = current_flags & ~nonblocking;
    while (true) {
        const result = std.posix.system.fcntl(fd, std.posix.F.SETFL, blocking_flags);
        switch (std.posix.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.CodexCredentialFdUnavailable,
        }
    }
}

fn suppressSigPipe(fd: std.c.fd_t) !void {
    if (comptime !@hasDecl(std.c.SO, "NOSIGPIPE")) return;
    var enable: c_int = 1;
    if (std.c.setsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.NOSIGPIPE,
        &enable,
        @sizeOf(c_int),
    ) != 0) return error.CodexCredentialFdUnavailable;
}

fn validateConnectedLocalStream(fd: std.c.fd_t) !void {
    var socket_type: c_int = 0;
    var socket_type_len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.TYPE,
        &socket_type,
        &socket_type_len,
    ) != 0 or socket_type_len != @sizeOf(c_int) or socket_type != std.c.SOCK.STREAM) {
        return error.CodexCredentialFdNotLocalStream;
    }

    var local_address: std.c.sockaddr.storage = undefined;
    var local_address_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.storage);
    if (std.c.getsockname(fd, @ptrCast(&local_address), &local_address_len) != 0 or
        local_address.family != std.c.AF.UNIX)
    {
        return error.CodexCredentialFdNotLocalStream;
    }

    var peer_address: std.c.sockaddr.storage = undefined;
    var peer_address_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.storage);
    if (std.c.getpeername(fd, @ptrCast(&peer_address), &peer_address_len) != 0 or
        peer_address.family != std.c.AF.UNIX)
    {
        return error.CodexCredentialFdNotConnected;
    }
}

fn readPeerIdentity(fd: std.c.fd_t) !PeerIdentity {
    if (comptime builtin.os.tag == .macos) {
        var peer_uid: std.c.uid_t = undefined;
        var peer_gid: std.c.gid_t = undefined;
        const Peer = struct {
            extern "c" fn getpeereid(
                socket: std.c.fd_t,
                effective_uid: *std.c.uid_t,
                effective_gid: *std.c.gid_t,
            ) c_int;
        };
        if (Peer.getpeereid(fd, &peer_uid, &peer_gid) != 0) {
            return error.CodexCredentialPeerUnavailable;
        }
        const local_peer_pid = 0x002;
        var peer_pid: std.c.pid_t = undefined;
        var peer_pid_len: std.c.socklen_t = @sizeOf(std.c.pid_t);
        if (std.c.getsockopt(fd, 0, local_peer_pid, &peer_pid, &peer_pid_len) != 0 or
            peer_pid_len != @sizeOf(std.c.pid_t))
        {
            return error.CodexCredentialPeerUnavailable;
        }
        return .{ .uid = peer_uid, .pid = peer_pid };
    }
    if (comptime builtin.os.tag == .linux) {
        const UCred = extern struct {
            pid: std.c.pid_t,
            uid: std.c.uid_t,
            gid: std.c.gid_t,
        };
        var peer: UCred = undefined;
        var peer_len: std.c.socklen_t = @sizeOf(UCred);
        if (std.c.getsockopt(
            fd,
            std.c.SOL.SOCKET,
            std.c.SO.PEERCRED,
            &peer,
            &peer_len,
        ) != 0 or peer_len != @sizeOf(UCred)) {
            return error.CodexCredentialPeerUnavailable;
        }
        return .{ .uid = peer.uid, .pid = peer.pid };
    }
    return error.CodexCredentialPeerUnavailable;
}

fn shutdownSocket(fd: std.c.fd_t) void {
    _ = std.c.shutdown(fd, std.c.SHUT.RDWR);
}

fn closeSocket(fd: std.c.fd_t) void {
    // Never retry close(2) after EINTR: some kernels have already released the
    // descriptor, and a retry could close an unrelated fd that reused its number.
    _ = std.posix.system.close(fd);
}

var stable_test_environ: ?*std.process.Environ.Map = null;

/// Restores a process-wide environment view that outlives the test's own map.
fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const TestProvider = struct {
    tokens: []const []const u8 = &.{ "access-one", "access-two", "access-three" },
    index: usize = 0,
    deadline_ms: i64 = 1_000_000,
    account_id: []const u8 = "acct-one",
    stored_calls: usize = 0,
    force_calls: usize = 0,

    fn provider(self: *@This()) CredentialProvider {
        return .{ .context = self, .load_fn = load };
    }

    fn load(
        raw: ?*anyopaque,
        alloc: Allocator,
        mode: LoadMode,
        _: []const u8,
    ) anyerror!?Lease {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        switch (mode) {
            .stored => self.stored_calls += 1,
            .force => {
                self.force_calls += 1;
                self.index = @min(self.index + 1, self.tokens.len - 1);
                self.deadline_ms += 1_000_000;
            },
        }
        const access_token = try alloc.dupe(u8, self.tokens[self.index]);
        errdefer secret.zeroAndFree(alloc, access_token);
        const account_id = try alloc.dupe(u8, self.account_id);
        return .{
            .access_token = access_token,
            .account_id = account_id,
            .refresh_deadline_ms = self.deadline_ms,
        };
    }
};

fn fixedNow(_: ?*anyopaque) i64 {
    return 0;
}

fn testService(alloc: Allocator, provider: *TestProvider) Service {
    return .{
        .alloc = alloc,
        .provider = provider.provider(),
        .clock = .{ .now_fn = fixedNow },
        .expected_uid = 501,
        .nonce = ("a" ** nonce_len).*,
        .pinned_account_id = provider.account_id,
        .pinned_identity = credential_authority.derive(
            .chatgpt_subscription,
            provider.account_id,
        ).?,
    };
}

fn testRequest(
    alloc: Allocator,
    request_id: []const u8,
    nonce: []const u8,
    method: []const u8,
    params: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"schema\":1,\"request_id\":\"{s}\",\"nonce\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}",
        .{ request_id, nonce, method, params },
    );
}

fn takeResponse(result: HandleResult) []u8 {
    return switch (result) {
        .response => |value| value,
        .refuse => |value| value,
        .close => unreachable,
    };
}

fn responseField(
    alloc: Allocator,
    response: []const u8,
    section: []const u8,
    field: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response, .{});
    defer parsed.deinit();
    const container = parsed.value.object.get(section).?;
    const value = container.object.get(field).?;
    return switch (value) {
        .string => |text| alloc.dupe(u8, text),
        .integer => |number| std.fmt.allocPrint(alloc, "{d}", .{number}),
        else => error.TestUnexpectedResponseField,
    };
}

test "Codex credential broker admits only the pinned peer and instance nonce" {
    const alloc = std.testing.allocator;
    var provider = TestProvider{};
    var service = testService(alloc, &provider);
    const nonce = service.nonce;
    const peer = PeerIdentity{ .uid = 501, .pid = 4242 };
    const params = "{\"minimum_validity_seconds\":60}";

    const admitted = try testRequest(alloc, "1", &nonce, "codex.credential.resolve", params);
    defer alloc.free(admitted);
    const first = try service.handle(alloc, admitted, peer);
    const first_response = takeResponse(first);
    defer secret.zeroAndFree(alloc, first_response);
    try std.testing.expect(first == .response);
    // The first admitted request pins the peer process for the channel's life.
    try std.testing.expectEqual(@as(?std.c.pid_t, 4242), service.pinned_pid);

    const moved = try service.handle(alloc, admitted, .{ .uid = 501, .pid = 4243 });
    const moved_response = takeResponse(moved);
    defer secret.zeroAndFree(alloc, moved_response);
    try std.testing.expect(moved == .refuse);
    const moved_code = try responseField(alloc, moved_response, "error", "code");
    defer alloc.free(moved_code);
    try std.testing.expectEqualStrings("unauthorized", moved_code);

    const other_user = try service.handle(alloc, admitted, .{ .uid = 502, .pid = 4242 });
    const other_user_response = takeResponse(other_user);
    defer secret.zeroAndFree(alloc, other_user_response);
    try std.testing.expect(other_user == .refuse);

    const wrong_nonce = try testRequest(
        alloc,
        "2",
        "b" ** nonce_len,
        "codex.credential.resolve",
        params,
    );
    defer alloc.free(wrong_nonce);
    const forged = try service.handle(alloc, wrong_nonce, peer);
    const forged_response = takeResponse(forged);
    defer secret.zeroAndFree(alloc, forged_response);
    try std.testing.expect(forged == .refuse);

    // A request carrying no nonce at all is a protocol fault, not a lease.
    const absent = try std.fmt.allocPrint(
        alloc,
        "{{\"schema\":1,\"request_id\":\"3\",\"method\":\"codex.credential.resolve\",\"params\":{s}}}",
        .{params},
    );
    defer alloc.free(absent);
    const unsigned = try service.handle(alloc, absent, peer);
    try std.testing.expect(unsigned == .close);
    try std.testing.expectEqual(@as(usize, 1), provider.stored_calls);
}

test "Codex credential broker rotates one generation and answers a stale generation with the newer lease" {
    const alloc = std.testing.allocator;
    var provider = TestProvider{};
    var service = testService(alloc, &provider);
    const nonce = service.nonce;
    const peer = PeerIdentity{ .uid = 501, .pid = 77 };

    const resolve = try testRequest(
        alloc,
        "1",
        &nonce,
        "codex.credential.resolve",
        "{\"minimum_validity_seconds\":60}",
    );
    defer alloc.free(resolve);
    const resolved = takeResponse(try service.handle(alloc, resolve, peer));
    defer secret.zeroAndFree(alloc, resolved);
    const first_generation = try responseField(alloc, resolved, "result", "generation");
    defer alloc.free(first_generation);
    try std.testing.expectEqualStrings("1", first_generation);
    const first_token = try responseField(alloc, resolved, "result", "access_token");
    defer alloc.free(first_token);
    try std.testing.expectEqualStrings("access-one", first_token);

    const rotate = try testRequest(
        alloc,
        "2",
        &nonce,
        "codex.credential.refresh",
        "{\"account_id\":\"acct-one\",\"prior_generation\":1}",
    );
    defer alloc.free(rotate);
    const rotated = takeResponse(try service.handle(alloc, rotate, peer));
    defer secret.zeroAndFree(alloc, rotated);
    const rotated_generation = try responseField(alloc, rotated, "result", "generation");
    defer alloc.free(rotated_generation);
    try std.testing.expectEqualStrings("2", rotated_generation);
    const rotated_token = try responseField(alloc, rotated, "result", "access_token");
    defer alloc.free(rotated_token);
    try std.testing.expectEqualStrings("access-two", rotated_token);
    try std.testing.expectEqual(@as(usize, 1), provider.force_calls);

    // The same prior generation is now stale. It receives the already newer
    // lease unchanged rather than rotating the account a second time.
    const stale = takeResponse(try service.handle(alloc, rotate, peer));
    defer secret.zeroAndFree(alloc, stale);
    const stale_generation = try responseField(alloc, stale, "result", "generation");
    defer alloc.free(stale_generation);
    try std.testing.expectEqualStrings("2", stale_generation);
    const stale_token = try responseField(alloc, stale, "result", "access_token");
    defer alloc.free(stale_token);
    try std.testing.expectEqualStrings("access-two", stale_token);
    try std.testing.expectEqual(@as(usize, 1), provider.force_calls);

    const future = try testRequest(
        alloc,
        "3",
        &nonce,
        "codex.credential.refresh",
        "{\"account_id\":\"acct-one\",\"prior_generation\":3}",
    );
    defer alloc.free(future);
    const refused = takeResponse(try service.handle(alloc, future, peer));
    defer secret.zeroAndFree(alloc, refused);
    const refused_code = try responseField(alloc, refused, "error", "code");
    defer alloc.free(refused_code);
    try std.testing.expectEqualStrings("future_generation", refused_code);
    try std.testing.expectEqual(@as(usize, 1), provider.force_calls);
}

test "Codex credential broker leases carry no refresh token or store representation" {
    const alloc = std.testing.allocator;
    var provider = TestProvider{};
    var service = testService(alloc, &provider);
    const nonce = service.nonce;
    const peer = PeerIdentity{ .uid = 501, .pid = 11 };

    const resolve = try testRequest(
        alloc,
        "1",
        &nonce,
        "codex.credential.resolve",
        "{\"minimum_validity_seconds\":60}",
    );
    defer alloc.free(resolve);
    const resolved = takeResponse(try service.handle(alloc, resolve, peer));
    defer secret.zeroAndFree(alloc, resolved);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resolved, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 4), result.count());
    try std.testing.expect(result.get("access_token") != null);
    try std.testing.expect(result.get("account_id") != null);
    try std.testing.expect(result.get("generation") != null);
    // The deadline is published in whole seconds, matching the request unit.
    try std.testing.expectEqual(@as(i64, 1_000), result.get("refresh_deadline").?.integer);

    // A refresh naming another account never reaches the credential store.
    const other = try testRequest(
        alloc,
        "2",
        &nonce,
        "codex.credential.refresh",
        "{\"account_id\":\"acct-two\",\"prior_generation\":1}",
    );
    defer alloc.free(other);
    const mismatch = takeResponse(try service.handle(alloc, other, peer));
    defer secret.zeroAndFree(alloc, mismatch);
    const mismatch_code = try responseField(alloc, mismatch, "error", "code");
    defer alloc.free(mismatch_code);
    try std.testing.expectEqualStrings("account_mismatch", mismatch_code);
    try std.testing.expectEqual(@as(usize, 0), provider.force_calls);

    // A store that answers with a different account fails the whole operation.
    provider.account_id = "acct-swapped";
    const swapped = takeResponse(try service.handle(alloc, resolve, peer));
    defer secret.zeroAndFree(alloc, swapped);
    const swapped_code = try responseField(alloc, swapped, "error", "code");
    defer alloc.free(swapped_code);
    try std.testing.expectEqualStrings("account_changed", swapped_code);
}

const TestChannel = struct {
    fx_end: std.c.fd_t,
    consumer_end: std.c.fd_t,

    fn open() !TestChannel {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
            return error.TestSocketPairUnavailable;
        }
        return .{ .fx_end = fds[0], .consumer_end = fds[1] };
    }

    fn deinit(self: *TestChannel) void {
        closeSocket(self.fx_end);
        closeSocket(self.consumer_end);
        self.* = undefined;
    }
};

fn readTestFrame(alloc: Allocator, fd: std.c.fd_t) ![]u8 {
    const frame = try readFrame(alloc, fd, 2_000);
    return switch (frame) {
        .eof => error.TestChannelClosed,
        .payload => |payload| payload,
    };
}

test "Codex credential broker frames one persistent channel and fails a stalled frame" {
    const alloc = std.testing.allocator;
    var channel = try TestChannel.open();
    defer channel.deinit();

    var provider = TestProvider{};
    const service = testService(alloc, &provider);
    const nonce = service.nonce;
    var worker = Worker{
        .alloc = alloc,
        .fd = channel.fx_end,
        .peer_probe = .{ .read_fn = struct {
            fn read(_: ?*anyopaque, _: std.c.fd_t) anyerror!PeerIdentity {
                return .{ .uid = 501, .pid = 99 };
            }
        }.read },
        .transport = oauth_transport.unavailable_provider,
        .oauth_cancel = std.atomic.Value(bool).init(false),
        .pinned_account_id = try alloc.dupe(u8, provider.account_id),
        .frame_deadline_ms = 200,
        .service = service,
    };
    defer secret.zeroAndFree(alloc, worker.pinned_account_id);
    worker.service.pinned_account_id = worker.pinned_account_id;

    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    const request = try testRequest(
        alloc,
        "1",
        &nonce,
        "codex.credential.resolve",
        "{\"minimum_validity_seconds\":60}",
    );
    defer alloc.free(request);
    try writeFrame(channel.consumer_end, request, 2_000);
    const first = try readTestFrame(alloc, channel.consumer_end);
    defer secret.zeroAndFree(alloc, first);
    const first_generation = try responseField(alloc, first, "result", "generation");
    defer alloc.free(first_generation);
    try std.testing.expectEqualStrings("1", first_generation);

    // The channel is persistent: a second request needs no new connection.
    const second = try testRequest(
        alloc,
        "2",
        &nonce,
        "codex.credential.refresh",
        "{\"account_id\":\"acct-one\",\"prior_generation\":1}",
    );
    defer alloc.free(second);
    try writeFrame(channel.consumer_end, second, 2_000);
    const rotated = try readTestFrame(alloc, channel.consumer_end);
    defer secret.zeroAndFree(alloc, rotated);
    const rotated_generation = try responseField(alloc, rotated, "result", "generation");
    defer alloc.free(rotated_generation);
    try std.testing.expectEqualStrings("2", rotated_generation);

    // A length prefix whose payload never arrives fails on the frame deadline
    // instead of holding the channel open forever.
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, 64, .big);
    try writeAll(channel.consumer_end, &prefix, io_mod.milliTimestamp() + 2_000);
    thread.join();
    try std.testing.expectEqual(@as(usize, 1), provider.force_calls);
}

test "Codex credential broker fails closed for host-managed and borrowed authority" {
    const alloc = std.testing.allocator;
    const channel = try TestChannel.open();
    defer closeSocket(channel.consumer_end);

    const stable_environ = try stableEmptyTestEnviron();
    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    io_mod.setEnvironMap(&environ);
    defer io_mod.setEnvironMap(stable_environ);

    var runtime = Runtime{};
    var activation = Activation{ .fd = channel.fx_end };
    try std.testing.expectError(
        error.CodexCredentialBrokerHostManagedAuth,
        runtime.start(alloc, &activation, .{
            .transport = oauth_transport.unavailable_provider,
            .secret_store = host.unavailable_secret_store,
            .auth_mode = .host_managed,
        }),
    );
    try std.testing.expect(!runtime.active());
    try std.testing.expect(!activation.active());

    const borrowed_channel = try TestChannel.open();
    defer closeSocket(borrowed_channel.consumer_end);
    try environ.put(read_only_home_env, "/somewhere/else");
    try std.testing.expect(borrowedAuthorizationConfigured());
    var borrowed_activation = Activation{ .fd = borrowed_channel.fx_end };
    try std.testing.expectError(
        error.CodexCredentialBrokerBorrowedAuth,
        runtime.start(alloc, &borrowed_activation, .{
            .transport = oauth_transport.unavailable_provider,
            .secret_store = host.unavailable_secret_store,
            .auth_mode = .local,
        }),
    );
    try std.testing.expect(!runtime.active());
}
