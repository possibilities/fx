const std = @import("std");
const builtin_gateway = @import("../builtins/gateway.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_client = @import("client.zig");
const host_stream_provider = @import("host_stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");

const Allocator = std.mem.Allocator;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const max_catalog_entries: usize = 10_000;
const catalog_timeout_ms: i64 = 30_000;
const catalog_poll_ms: u64 = 25;
const e2e_models_url_env = "FX_E2E_GATEWAY_MODELS_URL";
const e2e_timeout_ms_env = "FX_E2E_GATEWAY_CATALOG_TIMEOUT_MS";

/// Borrows the host transport for the lifetime of the provider.
pub fn provider(transport: *host_stream_provider.Transport) model_catalog.Provider {
    return .{
        .context = transport,
        .fetch_fn = fetch,
        .provider_id = .gateway,
    };
}

fn fetch(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const transport: *host_stream_provider.Transport = @ptrCast(@alignCast(raw.?));
    if (input.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    }
    const deadline = catalogDeadline();

    const url = catalogUrl(alloc, input.endpoint) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(url);

    const Header = struct { name: []const u8, value: []const u8 };
    var headers: std.ArrayList(Header) = .empty;
    defer headers.deinit(alloc);
    const authorization = if (input.access.authorizationCredential()) |credential|
        try std.fmt.allocPrint(alloc, "Bearer {s}", .{credential})
    else
        null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    if (authorization) |value| try headers.append(alloc, .{ .name = "authorization", .value = value });
    if (input.access.teamContext()) |team| {
        try headers.append(alloc, .{ .name = "x-vercel-ai-gateway-team", .value = team });
    }

    var headers_json: std.Io.Writer.Allocating = .init(alloc);
    defer {
        const serialized = headers_json.writer.buffered();
        if (serialized.len > 0) std.crypto.secureZero(u8, @constCast(@volatileCast(serialized)));
        headers_json.deinit();
    }
    std.json.Stringify.value(headers.items, .{}, &headers_json.writer) catch return error.OutOfMemory;

    const handle = transport.open("GET", url, headers_json.writer.buffered(), &.{}) catch
        return .{ .failure = .{ .category = .transport, .retryable = true } };
    defer transport.close(handle);

    var status_code: u16 = 0;
    while (true) {
        if (cancelled(input.cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
        if (deadlineExpired(deadline)) return .{ .failure = .{ .category = .transport, .retryable = true } };
        const status_result = transport.status(handle, &status_code);
        if (status_result == 1) break;
        if (status_result == -2) return .{ .failure = .{ .category = .cancellation } };
        if (status_result < 0) return .{ .failure = .{ .category = .transport, .retryable = true } };
        io_mod.sleep(catalog_poll_ms * std.time.ns_per_ms);
    }
    if (status_code != @intFromEnum(std.http.Status.ok)) {
        return .{ .failure = model_catalog.failureForHttpStatus(@enumFromInt(status_code)) };
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        if (cancelled(input.cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
        if (deadlineExpired(deadline)) return .{ .failure = .{ .category = .transport, .retryable = true } };
        const count = transport.next(handle, &chunk);
        if (count == -3) {
            io_mod.sleep(catalog_poll_ms * std.time.ns_per_ms);
            continue;
        }
        if (count == -2) return .{ .failure = .{ .category = .cancellation } };
        if (count < 0) return .{ .failure = .{ .category = .transport, .retryable = true } };
        if (count == 0) break;
        const len: usize = @intCast(count);
        if (len > max_catalog_bytes - body.items.len) {
            return .{ .failure = .{ .category = .resource_exhausted } };
        }
        try body.appendSlice(alloc, chunk[0..len]);
    }

    const entry_count = catalogEntryCount(alloc, body.items) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    if (entry_count > max_catalog_entries) {
        return .{ .failure = .{ .category = .resource_exhausted } };
    }

    const catalog = builtin_gateway.parseModelCatalogForView(alloc, body.items, input.view) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

fn cancelled(flag: ?*std.atomic.Value(bool)) bool {
    return if (flag) |value| value.load(.seq_cst) else false;
}

fn catalogDeadline() std.Io.Clock.Timestamp {
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const configured = if (io_mod.getenv(e2e_timeout_ms_env)) |raw|
        std.fmt.parseInt(i64, raw, 10) catch catalog_timeout_ms
    else
        catalog_timeout_ms;
    const timeout_ms = if (configured > 0 and configured <= catalog_timeout_ms)
        configured
    else
        catalog_timeout_ms;
    return .{
        .clock = .awake,
        .raw = started.raw.addDuration(.fromMilliseconds(timeout_ms)),
    };
}

fn deadlineExpired(deadline: std.Io.Clock.Timestamp) bool {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

fn catalogEntryCount(alloc: Allocator, body: []const u8) !usize {
    var scanner = std.json.Scanner.initCompleteInput(alloc, body);
    defer scanner.deinit();

    switch (try scanner.next()) {
        .object_begin => {},
        else => return error.MalformedResponse,
    }
    var entry_count: ?usize = null;
    while (true) {
        switch (try scanner.peekNextTokenType()) {
            .object_end => {
                _ = try scanner.next();
                break;
            },
            .string => {},
            else => return error.MalformedResponse,
        }

        const key_is_data = key: {
            const token = try scanner.nextAllocMax(alloc, .alloc_if_needed, max_catalog_bytes);
            defer switch (token) {
                .allocated_string => |value| alloc.free(value),
                else => {},
            };
            const value = switch (token) {
                .string => |value| value,
                .allocated_string => |value| value,
                else => return error.MalformedResponse,
            };
            break :key std.mem.eql(u8, value, "data");
        };
        if (!key_is_data) {
            try scanner.skipValue();
            continue;
        }
        if (entry_count != null) return error.MalformedResponse;
        switch (try scanner.next()) {
            .array_begin => {},
            else => return error.MalformedResponse,
        }
        var count: usize = 0;
        while (true) {
            if (try scanner.peekNextTokenType() == .array_end) {
                _ = try scanner.next();
                break;
            }
            if (count == max_catalog_entries) return max_catalog_entries + 1;
            count += 1;
            try scanner.skipValue();
        }
        entry_count = count;
    }
    switch (try scanner.next()) {
        .end_of_document => {},
        else => return error.MalformedResponse,
    }
    return entry_count orelse error.MalformedResponse;
}

fn catalogUrl(alloc: Allocator, path: []const u8) ![]u8 {
    if (io_mod.getenv(e2e_models_url_env)) |candidate| {
        if (!gateway_client.isLoopbackHttpUrl(candidate)) return error.InvalidCatalogUrl;
        return alloc.dupe(u8, candidate);
    }
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ builtin_gateway.default_model_catalog_base_url, path });
}

test "host model catalog preflight bounds entries before full parsing" {
    const alloc = std.testing.allocator;
    for ([_]usize{ max_catalog_entries, max_catalog_entries + 1 }) |count| {
        var body: std.Io.Writer.Allocating = .init(alloc);
        defer body.deinit();
        try body.writer.writeAll("{\"metadata\":{\"nested\":[1]},\"data\":[");
        for (0..count) |index| {
            if (index > 0) try body.writer.writeByte(',');
            try body.writer.writeAll("{}");
        }
        try body.writer.writeAll("]}");

        try std.testing.expectEqual(
            @min(count, max_catalog_entries + 1),
            try catalogEntryCount(alloc, body.writer.buffered()),
        );
    }
}

test "host model catalog preflight requires one data array" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.MalformedResponse,
        catalogEntryCount(alloc, "{\"data\":{}}"),
    );
    try std.testing.expectError(
        error.MalformedResponse,
        catalogEntryCount(alloc, "{\"data\":[],\"data\":[]}"),
    );
}
