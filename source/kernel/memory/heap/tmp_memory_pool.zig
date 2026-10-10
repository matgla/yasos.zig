// Copyright (c) 2025 Mateusz Stadnik
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

const builtin = @import("builtin");
const std = @import("std");

pub fn TmpMemoryPool(comptime page_size_bytes: usize) type {
    comptime {
        std.debug.assert(std.math.isPowerOfTwo(page_size_bytes));
        std.debug.assert(page_size_bytes >= 16);
    }

    return struct {
        pub const page_size = page_size_bytes;
        const Self = @This();

        memory_size: usize,
        page_count: usize,
        page_bitmap: std.DynamicBitSet,
        start_address: usize,
        /// High-water mark in pages. The arena is deliberately smaller than the
        /// largest file it may be asked to hold, so what matters is not whether
        /// it is full now but whether it ever was: a request it cannot satisfy
        /// does not fail, it silently sends that file to the SD card. This is
        /// the only way to see that from outside.
        peak_pages: usize = 0,
        /// Pages in use; kept here because counting the bitmap on every
        /// allocation costs a pass over the whole arena (64 MiB = 262144 pages
        /// on the an524).
        used_pages: usize = 0,
        /// Every page below this index is in use, so the first-fit search can
        /// start here instead of rescanning the full prefix of the arena.
        free_hint: usize = 0,
        /// Bitmap probes made by the free-range search (test builds only):
        /// lets the tests check that allocation cost stays independent of how
        /// full the arena is.
        search_steps: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {},

        pub fn init(allocator: std.mem.Allocator, memory: []align(page_size) u8) !Self {
            const usable_page_count = memory.len / page_size;
            return .{
                .memory_size = usable_page_count * page_size,
                .page_count = usable_page_count,
                .page_bitmap = try std.DynamicBitSet.initEmpty(allocator, usable_page_count),
                .start_address = @intFromPtr(memory.ptr),
            };
        }

        pub fn deinit(self: *Self) void {
            self.page_bitmap.deinit();
        }

        const MaskInt = std.DynamicBitSetUnmanaged.MaskInt;
        const mask_bits = @bitSizeOf(MaskInt);

        /// First index in [from, limit) whose bit is `want_set`, a word at a time.
        fn next_bit(self: *Self, from: usize, limit: usize, comptime want_set: bool) ?usize {
            if (from >= limit) {
                return null;
            }
            const masks = self.page_bitmap.unmanaged.masks;
            var word = from / mask_bits;
            var bits = if (want_set) masks[word] else ~masks[word];
            bits &= ~@as(MaskInt, 0) << @intCast(from % mask_bits);
            while (true) {
                if (builtin.is_test) self.search_steps += 1;
                if (bits != 0) {
                    const index = word * mask_bits + @ctz(bits);
                    return if (index < limit) index else null;
                }
                word += 1;
                if (word * mask_bits >= limit) {
                    return null;
                }
                bits = if (want_set) masks[word] else ~masks[word];
            }
        }

        /// Lowest run of `number_of_pages` free pages (first fit).
        fn find_free_range(self: *Self, number_of_pages: usize) ?usize {
            if (number_of_pages == 0 or number_of_pages > self.page_count) {
                return null;
            }

            // The first free page at or above the hint is the lowest free page.
            var start_index = self.next_bit(self.free_hint, self.page_count, false) orelse {
                self.free_hint = self.page_count;
                return null;
            };
            self.free_hint = start_index;
            while (start_index + number_of_pages <= self.page_count) {
                const used = self.next_bit(start_index, start_index + number_of_pages, true) orelse return start_index;
                start_index = self.next_bit(used + 1, self.page_count, false) orelse return null;
            }

            return null;
        }

        /// Pages in [start, end) that are in use.
        fn used_in_range(self: *Self, start: usize, end: usize) usize {
            var used: usize = 0;
            var index = start;
            while (self.next_bit(index, end, true)) |set| {
                used += 1;
                index = set + 1;
            }
            return used;
        }

        fn release_range(self: *Self, start: usize, end: usize) void {
            if (start >= end) {
                return;
            }
            self.used_pages -= self.used_in_range(start, end);
            self.page_bitmap.setRangeValue(.{ .start = start, .end = end }, false);
            if (start < self.free_hint) {
                self.free_hint = start;
            }
        }

        fn claim_range(self: *Self, start: usize, end: usize) void {
            self.page_bitmap.setRangeValue(.{ .start = start, .end = end }, true);
            self.used_pages += end - start;
            if (start == self.free_hint) {
                self.free_hint = end;
            }
            if (self.used_pages > self.peak_pages) {
                self.peak_pages = self.used_pages;
            }
        }

        fn range_slice(self: *Self, start_index: usize, number_of_pages: usize) []u8 {
            return @as([*]u8, @ptrFromInt(self.start_address + start_index * page_size))[0 .. number_of_pages * page_size];
        }

        fn range_indices(self: *Self, address: *anyopaque, number_of_pages: usize) ?struct { start: usize, end: usize } {
            if (number_of_pages == 0) {
                return null;
            }

            const address_int = @intFromPtr(address);
            if (address_int < self.start_address or address_int >= self.start_address + self.memory_size) {
                return null;
            }

            const offset = address_int - self.start_address;
            if (@rem(offset, page_size) != 0) {
                return null;
            }

            const start_index = offset / page_size;
            const end_index = start_index + number_of_pages;
            if (end_index > self.page_count) {
                return null;
            }

            return .{
                .start = start_index,
                .end = end_index,
            };
        }

        pub fn allocate_pages(self: *Self, number_of_pages: i32) ?[]u8 {
            if (number_of_pages <= 0) {
                return null;
            }

            const pages: usize = @intCast(number_of_pages);
            const start_index = self.find_free_range(pages) orelse return null;
            self.claim_range(start_index, start_index + pages);
            const slice = self.range_slice(start_index, pages);
            @memset(slice, 0);
            return slice;
        }

        pub fn free_pages(self: *Self, address: *anyopaque, number_of_pages: i32) void {
            if (number_of_pages <= 0) {
                return;
            }

            const pages: usize = @intCast(number_of_pages);
            const range = self.range_indices(address, pages) orelse return;
            self.release_range(range.start, range.end);
        }

        pub fn shrink_pages(self: *Self, address: *anyopaque, old_pages: i32, new_pages: i32) ?[]u8 {
            if (new_pages <= 0 or old_pages <= 0 or new_pages > old_pages) {
                return null;
            }

            const old_pages_usize: usize = @intCast(old_pages);
            const new_pages_usize: usize = @intCast(new_pages);
            const range = self.range_indices(address, old_pages_usize) orelse return null;

            self.release_range(range.start + new_pages_usize, range.end);

            return self.range_slice(range.start, new_pages_usize);
        }

        pub fn try_extend_pages(self: *Self, address: *anyopaque, old_pages: i32, new_pages: i32) ?[]u8 {
            if (old_pages <= 0 or new_pages <= old_pages) {
                return null;
            }

            const old_pages_usize: usize = @intCast(old_pages);
            const new_pages_usize: usize = @intCast(new_pages);
            const range = self.range_indices(address, old_pages_usize) orelse return null;
            const new_end = range.start + new_pages_usize;
            if (new_end > self.page_count) {
                return null;
            }

            if (self.next_bit(range.end, new_end, true) != null) {
                return null;
            }
            self.claim_range(range.end, new_end);

            const slice = self.range_slice(range.start, new_pages_usize);
            @memset(slice[old_pages_usize * page_size ..], 0);
            return slice;
        }

        pub fn get_used_size(self: Self) usize {
            return self.used_pages * page_size;
        }

        /// Largest the arena has ever been, in bytes.
        pub fn get_peak_size(self: Self) usize {
            return self.peak_pages * page_size;
        }
    };
}

const TestPool = TmpMemoryPool(256);

fn test_arena(pages: usize) ![]align(256) u8 {
    return std.testing.allocator.alignedAlloc(u8, .fromByteUnits(256), pages * 256);
}

test "TmpMemoryPool.AllocatesFirstFit" {
    const memory = try test_arena(16);
    defer std.testing.allocator.free(memory);
    var pool = try TestPool.init(std.testing.allocator, memory);
    defer pool.deinit();

    const a = pool.allocate_pages(1).?;
    const b = pool.allocate_pages(2).?;
    const c = pool.allocate_pages(1).?;
    try std.testing.expectEqual(@intFromPtr(memory.ptr), @intFromPtr(a.ptr));
    try std.testing.expectEqual(@intFromPtr(memory.ptr) + 256, @intFromPtr(b.ptr));
    try std.testing.expectEqual(@intFromPtr(memory.ptr) + 3 * 256, @intFromPtr(c.ptr));

    // A freed hole is reused by the first request that fits in it ...
    pool.free_pages(b.ptr, 2);
    const d = pool.allocate_pages(1).?;
    try std.testing.expectEqual(@intFromPtr(b.ptr), @intFromPtr(d.ptr));
    // ... and skipped by one that does not.
    const e = pool.allocate_pages(2).?;
    try std.testing.expectEqual(@intFromPtr(memory.ptr) + 4 * 256, @intFromPtr(e.ptr));
    const f = pool.allocate_pages(1).?;
    try std.testing.expectEqual(@intFromPtr(memory.ptr) + 2 * 256, @intFromPtr(f.ptr));

    // The whole arena, then nothing more.
    pool.free_pages(memory.ptr, 16);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
    const all = pool.allocate_pages(16).?;
    try std.testing.expectEqual(@intFromPtr(memory.ptr), @intFromPtr(all.ptr));
    try std.testing.expect(pool.allocate_pages(1) == null);
    try std.testing.expect(pool.allocate_pages(17) == null);
}

test "TmpMemoryPool.TracksUsedAndPeakAcrossShrinkAndExtend" {
    const memory = try test_arena(8);
    defer std.testing.allocator.free(memory);
    var pool = try TestPool.init(std.testing.allocator, memory);
    defer pool.deinit();

    const a = pool.allocate_pages(3).?;
    try std.testing.expectEqual(@as(usize, 3 * 256), pool.get_used_size());
    try std.testing.expect(pool.shrink_pages(a.ptr, 3, 1) != null);
    try std.testing.expectEqual(@as(usize, 256), pool.get_used_size());
    try std.testing.expect(pool.try_extend_pages(a.ptr, 1, 5) != null);
    try std.testing.expectEqual(@as(usize, 5 * 256), pool.get_used_size());
    const b = pool.allocate_pages(3).?;
    try std.testing.expectEqual(@intFromPtr(memory.ptr) + 5 * 256, @intFromPtr(b.ptr));
    try std.testing.expect(pool.try_extend_pages(a.ptr, 5, 6) == null);
    pool.free_pages(a.ptr, 5);
    pool.free_pages(b.ptr, 3);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
    try std.testing.expectEqual(@as(usize, 8 * 256), pool.get_peak_size());
}

// /tmp grows files a page at a time, so the cost of one allocation must not
// depend on how much of the arena is already in use: with the an524's 64 MiB
// arena (262144 pages) a scan over the used prefix made every write to /tmp
// quadratic and the self-host build ~10x slower.  Filling 65536 pages one by one
// (then refilling a freed checkerboard) must cost a few bitmap words per
// page, not a scan of the prefix.
test "TmpMemoryPool.SinglePageAllocationDoesNotRescanTheUsedPrefix" {
    const pages = 65536;
    const memory = try test_arena(pages);
    defer std.testing.allocator.free(memory);
    var pool = try TestPool.init(std.testing.allocator, memory);
    defer pool.deinit();

    for (0..pages) |i| {
        const page = pool.allocate_pages(1).?;
        try std.testing.expectEqual(@intFromPtr(memory.ptr) + i * 256, @intFromPtr(page.ptr));
    }
    try std.testing.expect(pool.allocate_pages(1) == null);
    var i: usize = 0;
    while (i < pages) : (i += 2) pool.free_pages(memory.ptr + i * 256, 1);
    i = 0;
    while (i < pages) : (i += 2) {
        const page = pool.allocate_pages(1).?;
        try std.testing.expectEqual(@intFromPtr(memory.ptr) + i * 256, @intFromPtr(page.ptr));
    }
    try std.testing.expectEqual(@as(usize, pages * 256), pool.get_used_size());
    // 98304 allocations: a scan that skips used words and starts at the
    // lowest free page looks at a couple of bitmap words each.  The old
    // per-bit scan of the used prefix looked at ~3.2e9 bits.
    try std.testing.expect(pool.search_steps < 8 * (pages + pages / 2));
}
