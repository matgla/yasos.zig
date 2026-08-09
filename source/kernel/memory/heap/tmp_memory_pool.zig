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

        fn find_free_range(self: *Self, number_of_pages: usize) ?usize {
            if (number_of_pages == 0 or number_of_pages > self.page_count) {
                return null;
            }

            var start_index: usize = 0;
            while (start_index + number_of_pages <= self.page_count) : (start_index += 1) {
                var offset: usize = 0;
                while (offset < number_of_pages) : (offset += 1) {
                    if (self.page_bitmap.isSet(start_index + offset)) {
                        start_index += offset;
                        break;
                    }
                } else {
                    return start_index;
                }
            }

            return null;
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
            for (start_index..start_index + pages) |index| {
                self.page_bitmap.set(index);
            }
            const slice = self.range_slice(start_index, pages);
            const used = self.page_bitmap.count();
            if (used > self.peak_pages) {
                self.peak_pages = used;
            }
            @memset(slice, 0);
            return slice;
        }

        pub fn free_pages(self: *Self, address: *anyopaque, number_of_pages: i32) void {
            if (number_of_pages <= 0) {
                return;
            }

            const pages: usize = @intCast(number_of_pages);
            const range = self.range_indices(address, pages) orelse return;
            for (range.start..range.end) |index| {
                self.page_bitmap.unset(index);
            }
        }

        pub fn shrink_pages(self: *Self, address: *anyopaque, old_pages: i32, new_pages: i32) ?[]u8 {
            if (new_pages <= 0 or old_pages <= 0 or new_pages > old_pages) {
                return null;
            }

            const old_pages_usize: usize = @intCast(old_pages);
            const new_pages_usize: usize = @intCast(new_pages);
            const range = self.range_indices(address, old_pages_usize) orelse return null;

            for (range.start + new_pages_usize..range.end) |index| {
                self.page_bitmap.unset(index);
            }

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

            for (range.end..new_end) |index| {
                if (self.page_bitmap.isSet(index)) {
                    return null;
                }
            }

            for (range.end..new_end) |index| {
                self.page_bitmap.set(index);
            }

            const slice = self.range_slice(range.start, new_pages_usize);
            @memset(slice[old_pages_usize * page_size ..], 0);
            return slice;
        }

        pub fn get_used_size(self: Self) usize {
            return self.page_bitmap.count() * page_size;
        }

        /// Largest the arena has ever been, in bytes.
        pub fn get_peak_size(self: Self) usize {
            return self.peak_pages * page_size;
        }
    };
}
