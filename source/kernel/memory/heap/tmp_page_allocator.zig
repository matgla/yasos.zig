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

pub fn TmpPageAllocator(comptime MemoryPoolType: anytype) type {
    return struct {
        _pool: *MemoryPoolType,

        const Self = @This();

        pub fn init(pool: *MemoryPoolType) Self {
            return .{
                ._pool = pool,
            };
        }

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

        fn calculate_number_of_pages(len: usize) i32 {
            return @intCast((len + MemoryPoolType.page_size - 1) / MemoryPoolType.page_size);
        }

        fn alloc(
            ctx: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            return_address: usize,
        ) ?[*]u8 {
            _ = return_address;
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (alignment.toByteUnits() > MemoryPoolType.page_size) {
                return null;
            }
            return @as([*]u8, @ptrCast(self._pool.allocate_pages(calculate_number_of_pages(len)) orelse return null));
        }

        fn resize(
            ctx: *anyopaque,
            buf: []u8,
            log2_buf_align: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) bool {
            _ = log2_buf_align;
            _ = return_address;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const old_pages = calculate_number_of_pages(buf.len);
            const new_pages = calculate_number_of_pages(new_len);

            if (new_pages == old_pages) {
                return true;
            }

            if (new_pages < old_pages) {
                return self._pool.shrink_pages(buf.ptr, old_pages, new_pages) != null;
            }

            return self._pool.try_extend_pages(buf.ptr, old_pages, new_pages) != null;
        }

        fn remap(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) ?[*]u8 {
            return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
        }

        fn free(
            ctx: *anyopaque,
            buf: []u8,
            log2_buf_align: std.mem.Alignment,
            return_address: usize,
        ) void {
            _ = log2_buf_align;
            _ = return_address;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self._pool.free_pages(buf.ptr, calculate_number_of_pages(buf.len));
        }
    };
}
