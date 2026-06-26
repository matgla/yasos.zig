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

const kernel = @import("../../kernel.zig");
const perf = @import("../../interrupts/perf_profile.zig");

const log = kernel.log;

pub fn ProcessPageAllocator(comptime MemoryPoolType: anytype) type {
    return struct {
        _pid: c.pid_t,
        _pool: *MemoryPoolType,
        // Absolute ceiling on the total pages this process may own across all
        // tiers (image + stack + heap). maxInt = unlimited (the OS-default
        // "free to grow" heap). Exec sets a finite value from the YAFF
        // heap_size profile so the process is bounded to its declared footprint.
        _page_limit: usize = std.math.maxInt(usize),

        pub const Self = @This();

        pub fn init(pid: c.pid_t, pool: *MemoryPoolType) Self {
            return .{
                ._pid = pid,
                ._pool = pool,
                ._page_limit = std.math.maxInt(usize),
            };
        }

        pub fn deinit(self: *Self) void {
            self._pool.release_pages_for(self._pid);
        }

        /// The backing pool this process draws from. In production this is the
        /// process manager's shared pool; in unit tests it is the pool the
        /// process was constructed with. Used by deinit diagnostics so they read
        /// the owning pool rather than a global singleton.
        pub fn get_pool(self: *Self) *MemoryPoolType {
            return self._pool;
        }

        /// Bound the process to `limit` total pages (image+stack+heap). A request
        /// that would push the process past this ceiling fails the allocation
        /// (user malloc gets NULL), enforcing the per-image heap profile.
        pub fn set_page_limit(self: *Self, limit: usize) void {
            self._page_limit = limit;
        }

        /// Apply a YAFF heap_size profile: bound the heap to `heap_bytes` beyond
        /// the pages already resident (image + stack). 0xFFFFFFFF = unbounded
        /// (free to grow in the shared paged pool). Call after the stack is
        /// reallocated so the baseline captures the fixed sections.
        pub fn set_heap_limit_bytes(self: *Self, heap_bytes: u32) void {
            if (heap_bytes == 0xFFFFFFFF) {
                self._page_limit = std.math.maxInt(usize);
                return;
            }
            const page_size = MemoryPoolType.page_size;
            const baseline = self._pool.used_pages_for(self._pid);
            const heap_pages = (@as(usize, heap_bytes) + page_size - 1) / page_size;
            self._page_limit = baseline + heap_pages;
        }

        /// True if granting `requested` more pages would exceed the process's cap.
        fn would_exceed_limit(self: *Self, requested: i32) bool {
            if (self._page_limit == std.math.maxInt(usize)) return false;
            if (requested <= 0) return false;
            const used = self._pool.used_pages_for(self._pid);
            return used + @as(usize, @intCast(requested)) > self._page_limit;
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
            if (self.would_exceed_limit(number_of_pages)) return null;
            // Tag this as user heap (malloc/mmap) so the profiler can separate
            // it from loader-managed image/stack/thunk allocations.
            self._pool.tag_next_heap = true;
            return self._pool.allocate_pages(number_of_pages, self._pid);
        }

        pub fn release_pages(self: *Self, address: *anyopaque, number_of_pages: i32) void {
            self._pool.free_pages(address, number_of_pages, self._pid);
        }

        pub fn try_extend_pages(self: *Self, address: *anyopaque, old_pages: i32, new_pages: i32) ?[]u8 {
            if (self.would_exceed_limit(new_pages - old_pages)) return null;
            return self._pool.try_extend_pages(address, old_pages, new_pages, self._pid);
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
            const self: *Self = @ptrCast(@alignCast(ctx));
            const pages = calculate_number_of_pages(len);
            if (self.would_exceed_limit(pages)) return null;
            // Profiling: log loader (image/got/thunk) allocations with requested
            // size + call site so the per-process footprint can be attributed.
            perf.trace("ldralloc pid={d} len={d} pages={d} ra=0x{x}", .{ self._pid, len, pages, return_address });
            return @as([*]u8, @ptrCast(self._pool.allocate_pages(pages, self._pid) orelse null));
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

test "ProcessPageAllocator.HeapLimitCapsAllocations" {
    const PagePool = @import("process_memory_pool.zig").ProcessMemoryPool;
    var pool = try PagePool.init(std.testing.allocator);
    defer pool.deinit();

    const allocator_type = ProcessPageAllocator(PagePool);
    var allocator = allocator_type.init(7, &pool);
    defer allocator.deinit();

    const alloc = allocator.allocator();

    // Reserve a 2-page "image+stack" baseline, then bound the heap to 1 page
    // beyond it (set_heap_limit_bytes counts the current footprint as baseline).
    const baseline = try alloc.alloc(u8, 2 * PagePool.page_size);
    try std.testing.expect(baseline.len == 2 * PagePool.page_size);
    allocator.set_heap_limit_bytes(PagePool.page_size); // 1 page of heap allowed

    // One more page fits exactly at the ceiling.
    const within = try alloc.alloc(u8, PagePool.page_size);
    try std.testing.expect(within.len == PagePool.page_size);

    // The next page would exceed the cap and must fail (user malloc -> NULL).
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, PagePool.page_size));

    // Freeing the heap page drops back below the cap, so allocation succeeds again.
    alloc.free(within);
    const again = try alloc.alloc(u8, PagePool.page_size);
    try std.testing.expect(again.len == PagePool.page_size);

    // The sentinel restores unbounded growth.
    allocator.set_heap_limit_bytes(0xFFFFFFFF);
    const unbounded = try alloc.alloc(u8, 4 * PagePool.page_size);
    try std.testing.expect(unbounded.len == 4 * PagePool.page_size);
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
    try std.testing.expect(mem1.?.len == PagePool.page_size * 4);
    const mem2 = allocator.allocate_pages(2);
    try std.testing.expect(mem2 != null);
    try std.testing.expect(mem2.?.len == PagePool.page_size * 2);
    try std.testing.expect(mem1.?.ptr != mem2.?.ptr);
    allocator.release_pages(mem1.?.ptr, 4);
    const mem3 = allocator.allocate_pages(2);
    try std.testing.expect(mem3 != null);
    try std.testing.expect(mem3.?.len == PagePool.page_size * 2);
    try std.testing.expect(mem3.?.ptr == mem1.?.ptr);

    allocator.release_pages(mem2.?.ptr, 2);
}
