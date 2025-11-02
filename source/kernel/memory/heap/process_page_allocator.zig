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

test "ProcessPageAllocator.ShouldAllocateAndFreePages" {
    const PagePool = @import("process_memory_pool.zig").ProcessMemoryPool;
    var pool = try PagePool.init(std.testing.allocator);
    defer pool.deinit();

    const allocator_type = ProcessPageAllocator(PagePool);
    var allocator = allocator_type.init(42, &pool);
    defer allocator.deinit();

    const alloc = allocator.allocator();

    const mem1 = try alloc.alloc(u8, 8192);
    try std.testing.expect(mem1.len == 8192);
    const mem2 = try alloc.alloc(u8, 4096);
    try std.testing.expect(mem2.len == 4096);
    try std.testing.expect(mem1.ptr != mem2.ptr);
}

test "ProcessPageAllocator.ResizeAndRemapShouldFail" {
    const PagePool = @import("process_memory_pool.zig").ProcessMemoryPool;
    var pool = try PagePool.init(std.testing.allocator);
    defer pool.deinit();

    const allocator_type = ProcessPageAllocator(PagePool);
    var allocator = allocator_type.init(42, &pool);
    defer allocator.deinit();

    const alloc = allocator.allocator();

    const mem1 = try alloc.alloc(u8, 8192);
    try std.testing.expect(mem1.len == 8192);
    const resized = alloc.resize(mem1, 1024);
    try std.testing.expect(!resized);
    try std.testing.expect(alloc.remap(mem1, 1024) == null);

    alloc.free(mem1);
    const mem2 = try alloc.alloc(u8, 4096);
    try std.testing.expect(mem2.len == 4096);
    try std.testing.expect(mem1.ptr == mem2.ptr);
}

test "ProcessPageAllocator.AllocateAndReleasePages" {
    const PagePool = @import("process_memory_pool.zig").ProcessMemoryPool;
    var pool = try PagePool.init(std.testing.allocator);
    defer pool.deinit();

    const allocator_type = ProcessPageAllocator(PagePool);
    var allocator = allocator_type.init(42, &pool);
    defer allocator.deinit();

    const mem1 = allocator.allocate_pages(4);
    try std.testing.expect(mem1 != null);
    try std.testing.expect(mem1.?.len == 4096 * 4);
    const mem2 = allocator.allocate_pages(2);
    try std.testing.expect(mem2 != null);
    try std.testing.expect(mem2.?.len == 4096 * 2);
    try std.testing.expect(mem1.?.ptr != mem2.?.ptr);
    allocator.release_pages(mem1.?.ptr, 4);
    const mem3 = allocator.allocate_pages(2);
    try std.testing.expect(mem3 != null);
    try std.testing.expect(mem3.?.len == 4096 * 2);
    try std.testing.expect(mem3.?.ptr == mem1.?.ptr);

    allocator.release_pages(mem2.?.ptr, 2);
}
