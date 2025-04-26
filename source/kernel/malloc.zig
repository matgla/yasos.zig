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

const log = &@import("../log/kernel_log.zig").kernel_log;

const process_memory_pool = @import("process_memory_pool.zig");

const MallocAllocator = struct {
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

        log.print("malloc alloc: {d}, {*}\n", .{ len, ptr });
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
        log.print("malloc free: {*}:{d}\n", .{ buf.ptr, buf.len });
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
    .remap = MallocAllocator.remap,
};

pub const ProcessPageAllocator = struct {
    pid: u32,

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        log2_align: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ProcessPageAllocator = @ptrCast(@alignCast(ctx));
        _ = log2_align;
        _ = return_address;
        const number_of_pages: i32 = @intCast((len + process_memory_pool.ProcessMemoryPool.page_size - 1) / process_memory_pool.ProcessMemoryPool.page_size);
        const ptr = @as([*]u8, @ptrCast(process_memory_pool.instance.allocate_pages(number_of_pages, self.pid) orelse return null));
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
        const self: *ProcessPageAllocator = @ptrCast(@alignCast(ctx));
        _ = log2_buf_align;
        _ = return_address;
        const number_of_pages: i32 = @intCast((buf.len + process_memory_pool.ProcessMemoryPool.page_size - 1) / process_memory_pool.ProcessMemoryPool.page_size);
        process_memory_pool.instance.free_pages(buf.ptr, number_of_pages, self.pid);
    }

    pub fn create(pid: u32) ProcessPageAllocator {
        return ProcessPageAllocator{
            .pid = pid,
        };
    }

    pub fn release_pages(self: *ProcessPageAllocator) void {
        process_memory_pool.instance.release_pages_for(self.pid);
    }

    pub fn std_allocator(self: *ProcessPageAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = @ptrCast(self),
            .vtable = &process_page_allocator_vtable,
        };
    }
};

const process_page_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = ProcessPageAllocator.alloc,
    .resize = ProcessPageAllocator.resize,
    .free = ProcessPageAllocator.free,
    .remap = ProcessPageAllocator.remap,
};
