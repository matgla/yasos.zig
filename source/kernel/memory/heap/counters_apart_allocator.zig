// Copyright (c) 2026 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.


// The allocator of an arena in PSRAM. An exclusive store to PSRAM never succeeds,
// so an atomic there spins for ever (sync/placement.zig), but nothing else about a
// tree of file metadata needs fast or coherent memory. The atomics in such a tree
// are its reference counters, allocated on their own, so what is that small goes
// to the kernel heap and everything else to the arena.
//
// Decided by size alone, which is also how `free` and `resize` find their way back:
// a request never changes sides. A name that short lands on the heap too, which is
// harmless. placement.assert_coherent, at each counter's construction, catches an
// atomic that ever outgrows this.

const std = @import("std");

/// `i32`, the largest reference counter in the tree.
pub const largest_counter = @sizeOf(i32);

pub const CountersApartAllocator = struct {
    arena: std.mem.Allocator,
    counters: std.mem.Allocator,

    const Self = @This();

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .remap = remap,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn side(self: *Self, len: usize) std.mem.Allocator {
        return if (len <= largest_counter) self.counters else self.arena;
    }

    fn stays_on_its_side(old_len: usize, new_len: usize) bool {
        return (old_len <= largest_counter) == (new_len <= largest_counter);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const target = self.side(len);
        return target.vtable.alloc(target.ptr, len, alignment, ret);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        if (!stays_on_its_side(buf.len, new_len)) return false;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const target = self.side(buf.len);
        return target.vtable.resize(target.ptr, buf, alignment, new_len, ret);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        if (!stays_on_its_side(buf.len, new_len)) return null;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const target = self.side(buf.len);
        return target.vtable.remap(target.ptr, buf, alignment, new_len, ret);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const target = self.side(buf.len);
        target.vtable.free(target.ptr, buf, alignment, ret);
    }
};

test "CountersApartAllocator.SendsCountersToOneSideAndTheRestToTheOther" {
    var arena_memory: [4096]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&arena_memory);
    var counters_memory: [256]u8 = undefined;
    var counters = std.heap.FixedBufferAllocator.init(&counters_memory);
    var sut = CountersApartAllocator{ .arena = arena.allocator(), .counters = counters.allocator() };
    const allocator = sut.allocator();

    const in_counters = struct {
        fn check(memory: []const u8, pointer: *const anyopaque) bool {
            const address = @intFromPtr(pointer);
            return address >= @intFromPtr(memory.ptr) and address < @intFromPtr(memory.ptr) + memory.len;
        }
    }.check;

    const big_counter = try allocator.create(i32);
    defer allocator.destroy(big_counter);
    const small_counter = try allocator.create(i16);
    defer allocator.destroy(small_counter);
    try std.testing.expect(in_counters(&counters_memory, big_counter));
    try std.testing.expect(in_counters(&counters_memory, small_counter));

    const node = try allocator.create(u64);
    defer allocator.destroy(node);
    try std.testing.expect(in_counters(&arena_memory, node));
}

test "CountersApartAllocator.ARequestNeverChangesSides" {
    var sut = CountersApartAllocator{ .arena = std.testing.allocator, .counters = std.testing.allocator };
    const allocator = sut.allocator();

    const small = try allocator.alloc(u8, largest_counter);
    defer allocator.free(small);
    try std.testing.expect(!allocator.resize(small, largest_counter + 1));

    const big = try allocator.alloc(u8, largest_counter + 1);
    defer allocator.free(big);
    try std.testing.expect(!allocator.resize(big, largest_counter));
    try std.testing.expect(allocator.remap(big, largest_counter) == null);
}
