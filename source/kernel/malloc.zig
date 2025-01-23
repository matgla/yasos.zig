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
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

const MallocAllocator = struct {
    fn alloc(
        _: *anyopaque,
        len: usize,
        log2_align: u8,
        return_address: usize,
    ) ?[*]u8 {
        _ = log2_align;
        _ = return_address;
        std.debug.assert(len > 0);
        const ptr = @as([*]u8, @ptrCast(c.malloc(len) orelse return null));
        return ptr;
    }

    fn resize(
        _: *anyopaque,
        buf: []u8,
        log2_buf_align: u8,
        new_len: usize,
        return_address: usize,
    ) bool {
        _ = return_address;
        _ = log2_buf_align;
        if (new_len <= buf.len) {
            return true;
        }

        const ptr = c.malloc(new_len);
        if (ptr == c.NULL) {
            return false;
        }
        if (buf.len > 0) {
            _ = c.memcpy(ptr, buf.ptr, buf.len);
        }
        return true;
    }

    fn free(
        _: *anyopaque,
        buf: []u8,
        log2_buf_align: u8,
        return_address: usize,
    ) void {
        _ = log2_buf_align;
        _ = return_address;
        c.free(buf.ptr);
    }
};

pub const malloc_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &malloc_allocator_vtable,
};

const malloc_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = MallocAllocator.alloc,
    .resize = MallocAllocator.resize,
    .free = MallocAllocator.free,
};
