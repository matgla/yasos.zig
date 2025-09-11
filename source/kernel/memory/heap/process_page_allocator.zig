//
// malloc.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//

const std = @import("std");
const c = @import("libc_imports").c;

const kernel = @import("kernel");

const log = kernel.log;

pub fn ProcessPageAllocator(comptime MemoryPoolType: anytype) type {
    return struct {
        _pid: c.pid_t,
        _pool: *MemoryPoolType,

        pub const Self = @This();

        pub fn init(pid: c.pid_t, pool: *MemoryPoolType) Self {
            return .{
                ._pid = pid,
                ._pool = pool,
            };
        }

        pub fn deinit(self: Self) void {
            self._pool.release_pages_for(self._pid);
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

        pub fn allocate_pages(self: *Self, number_of_pages: i32) ?[]u8 {
            return self._pool.allocate_pages(number_of_pages, self._pid);
        }

        pub fn release_pages(self: *Self, address: *anyopaque, number_of_pages: i32) void {
            self._pool.free_pages(address, number_of_pages, self._pid);
        }

        fn calculate_number_of_pages(len: usize) i32 {
            return @as(i32, @intCast((len + MemoryPoolType.page_size - 1) / MemoryPoolType.page_size));
        }

        fn alloc(
            ctx: *anyopaque,
            len: usize,
            log2_align: std.mem.Alignment,
            return_address: usize,
        ) ?[*]u8 {
            _ = log2_align;
            _ = return_address;
            const self: *Self = @ptrCast(@alignCast(ctx));
            return @as([*]u8, @ptrCast(self._pool.allocate_pages(calculate_number_of_pages(len), self._pid) orelse null));
        }

        fn resize(
            ctx: *anyopaque,
            buf: []u8,
            log2_buf_align: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) bool {
            _ = ctx;
            _ = buf;
            _ = return_address;
            _ = log2_buf_align;
            _ = new_len;

            return false;
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
            self._pool.free_pages(buf.ptr, calculate_number_of_pages(buf.len), self._pid);
        }
    };
}
