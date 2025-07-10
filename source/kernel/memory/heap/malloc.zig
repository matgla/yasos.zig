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

const c = @import("c").c;

pub fn MallocAllocator(comptime options: anytype) type {
    return struct {
        pub const Self = @This();

        pub fn init() Self {
            _ = options;
            return .{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
            // detect leaks here if enabled
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
            _: *anyopaque,
            len: usize,
            log2_align: std.mem.Alignment,
            return_address: usize,
        ) ?[*]u8 {
            _ = log2_align;
            _ = return_address;
            std.debug.assert(len > 0);
            const ptr = @as([*]u8, @ptrCast(c.malloc(len) orelse return null));

            return ptr;
        }

        fn resize(
            ctx: *anyopaque,
            buf: []u8,
            log2_buf_align: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) bool {
            _ = ctx;
            _ = return_address;
            _ = log2_buf_align;
            _ = buf;
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
            _: *anyopaque,
            buf: []u8,
            log2_buf_align: std.mem.Alignment,
            return_address: usize,
        ) void {
            _ = log2_buf_align;
            _ = return_address;
            c.free(buf.ptr);
        }
    };
}
