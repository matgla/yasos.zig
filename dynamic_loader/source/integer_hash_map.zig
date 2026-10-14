// Copyright (c) 2026 Mateusz Stadnik
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

pub fn IntegerHashMap(comptime K: type, comptime V: type) type {
    return std.HashMap(K, V, IntegerContext(K), std.hash_map.default_max_load_percentage);
}

/// Matches AutoContext for integer keys, without Wyhash's streaming state.
pub fn IntegerContext(comptime K: type) type {
    comptime {
        if (@typeInfo(K) != .int or !std.meta.hasUniqueRepresentation(K) or
            (@bitSizeOf(K) != 8 and @bitSizeOf(K) != 16 and @bitSizeOf(K) != 32 and @bitSizeOf(K) != 64))
            @compileError("IntegerContext requires an 8, 16, 32 or 64 bit integer");
    }
    return struct {
        pub inline fn hash(_: @This(), key: K) u64 {
            // Wyhash's seed-zero small-key path, kept scalar for Zig's C backend.
            const U = @Int(.unsigned, @bitSizeOf(K));
            const native: U = @bitCast(key);
            const n: u64 = if (comptime builtin.cpu.arch.endian() == .little) native else @byteSwap(native);
            const a: u64, const b: u64 = switch (@sizeOf(K)) {
                1 => .{ (n << 16) | (n << 8) | n, 0 },
                2 => .{ ((n & 0xff) << 16) | ((n >> 8) << 8) | (n >> 8), 0 },
                4 => .{ (n << 32) | n, (n << 32) | n },
                8 => .{ (n << 32) | (n >> 32), n },
                else => unreachable,
            };
            const secret0 = 0xa0761d6478bd642f;
            const secret1 = 0xe7037ed1a0b428db;
            const initial_state = comptime std.hash.Wyhash.init(0).state[0];
            const product = @as(u128, a ^ secret1) *% (b ^ initial_state);
            const lo: u64 = @truncate(product);
            const hi: u64 = @truncate(product >> 64);
            const final_product = @as(u128, lo ^ secret0 ^ @sizeOf(K)) *% (hi ^ secret1);
            return @as(u64, @truncate(final_product)) ^ @as(u64, @truncate(final_product >> 64));
        }

        pub fn eql(_: @This(), a: K, b: K) bool {
            return a == b;
        }
    };
}

test "integer hashes match AutoContext across widths and signedness" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, usize, isize }) |K| {
        const U = @Int(.unsigned, @bitSizeOf(K));
        const context: IntegerContext(K) = .{};
        const standard: std.hash_map.AutoContext(K) = .{};
        var random: u64 = 0x123456789abcdef0;
        for (0..1024) |i| {
            random = random *% 6364136223846793005 +% 1;
            const bits: U = switch (i) {
                0 => 0,
                1 => std.math.maxInt(U),
                2 => @as(U, 1) << (@bitSizeOf(K) - 1),
                else => @truncate(random),
            };
            const key: K = @bitCast(bits);
            try std.testing.expectEqual(standard.hash(key), context.hash(key));
        }
    }
}

test "integer maps retain entries through growth removal and cloning" {
    var map = IntegerHashMap(i32, u32).init(std.testing.allocator);
    defer map.deinit();
    for (0..256) |i| try map.put(@as(i32, @intCast(i)) - 128, @intCast(i));
    var copy = try map.clone();
    defer copy.deinit();
    for (0..256) |i| {
        const key = @as(i32, @intCast(i)) - 128;
        try std.testing.expectEqual(@as(u32, @intCast(i)), map.get(key).?);
        try std.testing.expect(map.remove(key));
        try std.testing.expectEqual(@as(u32, @intCast(i)), copy.get(key).?);
    }
    try std.testing.expectEqual(@as(u32, 0), map.count());
    try std.testing.expect(!map.remove(-1));
}

test "all file descriptor hashes match AutoContext" {
    const context: IntegerContext(u16) = .{};
    const standard: std.hash_map.AutoContext(u16) = .{};
    for (0..65536) |i| {
        const key: u16 = @intCast(i);
        try std.testing.expectEqual(standard.hash(key), context.hash(key));
    }
}

test "aligned image address keys survive collisions and resizing" {
    var map = IntegerHashMap(usize, usize).init(std.testing.allocator);
    defer map.deinit();
    const context: IntegerContext(usize) = .{};
    const standard: std.hash_map.AutoContext(usize) = .{};
    var buckets: [16]bool = @splat(false);
    var collisions: usize = 0;
    for (0..512) |i| {
        const key = 0x10000000 + i * 4096;
        const hash = context.hash(key);
        try std.testing.expectEqual(standard.hash(key), hash);
        const bucket = hash & 15;
        if (buckets[bucket]) collisions += 1;
        buckets[bucket] = true;
        try map.put(key, i);
    }
    try std.testing.expect(collisions > 0);
    for (0..512) |i| try std.testing.expectEqual(i, map.get(0x10000000 + i * 4096).?);
}
