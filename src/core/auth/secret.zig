const std = @import("std");

/// Delegates allocation while ensuring every released allocation is overwritten
/// first. Shrinking is deliberately refused because accepting it would discard
/// the only length capable of wiping the truncated tail on a later free.
pub const ZeroOnFreeAllocator = struct {
    const Self = @This();

    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) Self {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(raw));
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(raw));
        if (new_len < memory.len) return false;
        if (new_len == memory.len) return true;
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        std.crypto.secureZero(u8, @volatileCast(memory));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

/// Overwrite an owned secret before returning its allocation to the allocator.
pub noinline fn zeroAndFree(alloc: std.mem.Allocator, value: []u8) void {
    if (value.len == 0) return;
    std.crypto.secureZero(u8, @volatileCast(value));
    alloc.free(value);
}

test "zeroAndFree overwrites bytes before release" {
    var value = [_]u8{ 1, 2, 3 };
    std.crypto.secureZero(u8, @volatileCast(value[0..]));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &value);
}

test "zero-on-free allocator wipes the complete inspectable backing allocation" {
    var backing_bytes: [64]u8 = @splat(0xa5);
    var fixed = std.heap.FixedBufferAllocator.init(&backing_bytes);
    var wiping = ZeroOnFreeAllocator.init(fixed.allocator());
    const alloc = wiping.allocator();

    var value = try alloc.alloc(u8, 16);
    const offset = @intFromPtr(value.ptr) - @intFromPtr(backing_bytes[0..].ptr);
    try std.testing.expect(alloc.resize(value, 24));
    value = value.ptr[0..24];
    @memset(value, 0x5a);

    try std.testing.expect(!alloc.resize(value, 8));
    try std.testing.expect(alloc.remap(value, 32) == null);
    alloc.free(value);

    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
    for (backing_bytes[offset .. offset + value.len]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
