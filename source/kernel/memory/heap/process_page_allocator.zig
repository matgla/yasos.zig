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

/// Runs freed by a process are parked here instead of going back to the shared
/// pool, and handed to the same process again without being zeroed.
///
/// The zeroing in the pool exists so one process cannot read another's data. A
/// process reading back bytes it wrote itself leaks nothing, so the clear on
/// that path is pure cost -- and it is the dominant one: zeroing PSRAM runs at
/// 26 MB/s against SRAM's 933 MB/s, which made it 76% of all page-pool time
/// and 8% of a small tcc compile's wall clock. A cached run never re-enters the
/// pool's bitmap, so no other process can reach it before the owner exits.
///
/// The cost is memory held rather than returned, bounded by `cache_max_bytes`.
const page_cache_slots = 8;
const page_cache_max_bytes = 64 * 1024;

/// Off by default, because measurement says it earns nothing here: over 69
/// gcc_execute compiles it served **0 of 141** allocations. libc's own mapping
/// cache (malloc.c) absorbs the frees first, so almost nothing reaches this
/// layer to be parked, and a big compile ran no slower without it. Leaving it
/// off also keeps every page the kernel hands out zeroed, which is one less
/// thing to be careful about.
///
/// Kept rather than deleted: a process that calls mmap/munmap directly, without
/// libc's cache in front, would still be served by it. Turn it on and re-read
/// the `hits=`/`misses=` fields of the `poolprof` trace before believing it
/// helps.
pub var page_cache_enabled: bool = false;

pub fn ProcessPageAllocator(comptime MemoryPoolType: anytype) type {
    return struct {
        const CachedRun = struct {
            memory: ?[]u8 = null,
            pages: i32 = 0,
        };

        _pid: c.pid_t,
        _pool: *MemoryPoolType,
        _cache: [page_cache_slots]CachedRun = [_]CachedRun{.{}} ** page_cache_slots,
        _cache_bytes: usize = 0,
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

        /// Give every parked run back to the shared pool.
        fn cache_flush(self: *Self) void {
            for (&self._cache) |*slot| {
                const memory = slot.memory orelse continue;
                const pages = slot.pages;
                slot.* = .{};
                self._pool.free_pages(@ptrCast(memory.ptr), pages, self._pid);
            }
            self._cache_bytes = 0;
        }

        pub fn deinit(self: *Self) void {
            // release_pages_for would reclaim the parked runs anyway (they were
            // never returned to the pool, so they are still the pid's), but
            // clearing the slots keeps the allocator reusable after a deinit.
            self.cache_flush();
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

        /// Take a cached run of exactly `number_of_pages` back, if one is parked.
        ///
        /// Exact size only: the pool derives the run to release from the page
        /// count userspace passes to munmap, so handing back a larger run than
        /// was asked for would strand its tail until the process exits.
        fn cache_take(self: *Self, number_of_pages: i32) ?[]u8 {
            if (!page_cache_enabled) return null;
            for (&self._cache) |*slot| {
                if (slot.pages != number_of_pages) continue;
                const memory = slot.memory orelse continue;
                slot.* = .{};
                self._cache_bytes -= memory.len;
                return memory;
            }
            return null;
        }

        /// Park a run for reuse. False when it does not fit the budget or there
        /// is no free slot, in which case the caller frees it for real.
        fn cache_put(self: *Self, memory: []u8, number_of_pages: i32) bool {
            if (!page_cache_enabled) return false;
            if (self._cache_bytes + memory.len > page_cache_max_bytes) return false;
            // Only ever park memory this process really holds: the run is
            // handed back later without being cleared, so an unowned address
            // would be a way to read someone else's pages.
            if (!self._pool.owns_mapping(self._pid, memory.ptr, memory.len)) return false;
            for (&self._cache) |*slot| {
                if (slot.memory != null) continue;
                slot.* = .{ .memory = memory, .pages = number_of_pages };
                self._cache_bytes += memory.len;
                return true;
            }
            return false;
        }

        pub fn allocate_pages(self: *Self, number_of_pages: i32) ?[]u8 {
            if (self.cache_take(number_of_pages)) |memory| {
                perf.pool_cache_hit();
                return memory;
            }
            if (self.would_exceed_limit(number_of_pages)) {
                // Parked runs still count against the process's page limit, so
                // a bounded process must be able to spend them on a request of
                // a different size rather than fail with memory in hand.
                self.cache_flush();
                if (self.would_exceed_limit(number_of_pages)) return null;
            }
            // Tag this as user heap (malloc/mmap) so the profiler can separate
            // it from loader-managed image/stack/thunk allocations.
            self._pool.tag_next_heap = true;
            perf.pool_cache_miss();
            return self._pool.allocate_pages(number_of_pages, self._pid);
        }

        pub fn release_pages(self: *Self, address: *anyopaque, number_of_pages: i32) void {
            if (number_of_pages > 0) {
                const bytes = @as(usize, @intCast(number_of_pages)) * MemoryPoolType.page_size;
                const memory = @as([*]u8, @ptrCast(address))[0..bytes];
                if (self.cache_put(memory, number_of_pages)) return;
            }
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
            // Behind its own switch because this runs hundreds of times per
            // spawn and each line busy-waits on the UART -- see
            // perf.trace_allocations.
            if (comptime perf.trace_allocations) {
                perf.trace("ldralloc pid={d} len={d} pages={d} ra=0x{x}", .{ self._pid, len, pages, return_address });
            }
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
    // With the reuse cache off (the default), a release goes straight back to
    // the pool and its space is available to any later request.
    const mem3 = allocator.allocate_pages(2);
    try std.testing.expect(mem3 != null);
    try std.testing.expect(mem3.?.len == PagePool.page_size * 2);
    try std.testing.expect(mem3.?.ptr == mem1.?.ptr);

    allocator.release_pages(mem2.?.ptr, 2);
}

test "ProcessPageAllocator.ReusesAReleasedRunOfTheSameSize" {
    page_cache_enabled = true;
    defer page_cache_enabled = false;
    const PagePool = @import("process_memory_pool.zig").ProcessMemoryPool;
    var pool = try PagePool.init(std.testing.allocator);
    defer pool.deinit();

    var allocator = ProcessPageAllocator(PagePool).init(42, &pool);
    defer allocator.deinit();

    const first = allocator.allocate_pages(4) orelse return error.OutOfMemory;
    // Write a marker: the point of the cache is that the process gets these
    // exact bytes back, so the kernel does not have to zero them.
    first[0] = 0xAB;
    allocator.release_pages(first.ptr, 4);

    const second = allocator.allocate_pages(4) orelse return error.OutOfMemory;
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expectEqual(@as(u8, 0xAB), second[0]);
}

test "ProcessPageAllocator.DoesNotParkMemoryTheProcessDoesNotOwn" {
    page_cache_enabled = true;
    defer page_cache_enabled = false;
    const PagePool = @import("process_memory_pool.zig").ProcessMemoryPool;
    var pool = try PagePool.init(std.testing.allocator);
    defer pool.deinit();

    var allocator = ProcessPageAllocator(PagePool).init(42, &pool);
    defer allocator.deinit();

    // A run the pool handed to a *different* pid. Releasing it from this
    // process must not park it, or the next same-sized allocation here would
    // be handed another process's pages with their contents intact.
    const foreign = pool.allocate_pages(4, 7) orelse return error.OutOfMemory;
    allocator.release_pages(foreign.ptr, 4);

    const mine = allocator.allocate_pages(4) orelse return error.OutOfMemory;
    try std.testing.expect(mine.ptr != foreign.ptr);
}

test "ProcessPageAllocator.FlushesParkedRunsWhenTheLimitWouldBlockAnAllocation" {
    page_cache_enabled = true;
    defer page_cache_enabled = false;
    const PagePool = @import("process_memory_pool.zig").ProcessMemoryPool;
    var pool = try PagePool.init(std.testing.allocator);
    defer pool.deinit();

    var allocator = ProcessPageAllocator(PagePool).init(42, &pool);
    defer allocator.deinit();

    const first = allocator.allocate_pages(4) orelse return error.OutOfMemory;
    allocator.set_page_limit(pool.used_pages_for(42));
    allocator.release_pages(first.ptr, 4);

    // The parked run still counts against the limit, so without a flush this
    // request would fail with the memory sitting in the cache.
    const second = allocator.allocate_pages(2);
    try std.testing.expect(second != null);
}
