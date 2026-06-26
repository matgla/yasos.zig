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

const memory = @import("hal").memory;
const c = @import("libc_imports").c;

const kernel = @import("../../kernel.zig");
const perf = @import("../../interrupts/perf_profile.zig");

const log = std.log.scoped(.@"kernel/memory_pool");
// Only one process is owner of memory chunk
// shared memory will be implemented as seperate structure
//
// The pool is tiered: it manages an ordered list of memory regions and serves
// allocations from the fastest region that has room, spilling to the next.
// The regions are built fast-first (User SRAM = memory_layout[1]) then slow
// (PSRAM = memory_layout[2]), so process images and stacks land in fast SRAM
// whenever it has space and fall back to PSRAM only when SRAM is exhausted.
pub const ProcessMemoryPool = struct {
    // Minimum allocation granularity, and the unit callers count in. Each
    // Region picks its own (coarser-or-equal) page_size: fast SRAM tracks at
    // this fine 256 B grain so the loader's many sub-page allocations (argv,
    // thunks, small per-module blocks) stop wasting a 4 KiB page each, while
    // slow PSRAM stays at 4 KiB so its bitmap stays tiny. A request of N here
    // means N*page_size bytes; a region rounds that up to its own page count.
    pub const page_size = 256;
    // Per-tier page size: index 0 = fast SRAM (fine grain), 1 = PSRAM (coarse).
    const tier_page_sizes = [_]usize{ 256, 4096 };

    const AccessType = packed struct {
        read: u1,
        write: u1,
        execute: u1,
    };

    // Distinguishes user heap (mmap/malloc) allocations from loader-managed
    // ones (image data/bss/got, stack, thunks). Profiling only — lets the
    // per-pid dump attribute the footprint to reducible heap vs fixed image.
    pub const AllocSource = enum { loader, heap };

    const ProcessMemoryEntity = struct {
        address: []u8,
        pid: c.pid_t,
        access: AccessType,
        source: AllocSource,
        node: std.DoublyLinkedList.Node,
    };
    const ProcessMemoryList = std.DoublyLinkedList;
    const ProcessMemoryMap = std.AutoHashMap(c.pid_t, ProcessMemoryList);

    // A single contiguous backing region with its own page bitmap. Regions are
    // probed in order, so earlier (faster) regions are preferred.
    const Region = struct {
        start_address: usize,
        page_count: usize,
        // Allocation grain for THIS region (bytes). May differ per tier.
        page_size: usize,
        page_bitmap: std.DynamicBitSet,
        // High-water mark of used pages in this region since the last reset.
        // Diagnostic only (perf profiling): lets us see whether a process spilled
        // out of fast SRAM into slow PSRAM during a run.
        peak_used: usize = 0,
    };

    regions: []Region,
    memory_map: ProcessMemoryMap,
    // this allocator is used to keep track of the memory allocated for the process inside the kernel
    allocator: std.mem.Allocator,
    // Set by the user-mmap path immediately before allocate_pages so the next
    // allocation is tagged .heap; the loader path leaves it false (.loader).
    // Safe because mmap serializes via block_context_switch and exec is single
    // threaded. Profiling diagnostic only.
    tag_next_heap: bool = false,

    pub fn init(allocator: std.mem.Allocator) !ProcessMemoryPool {
        log.debug("Process memory pool initialized", .{});
        const memory_layout = memory.get_memory_layout();
        // Tier order: fast User SRAM first, slow PSRAM second. Skip any region
        // that is too small to hold a page (e.g. an rp2350 board without PSRAM
        // leaves memory_layout[2].size == 0).
        const tier_indices = [_]usize{ 1, 2 };

        var region_count: usize = 0;
        for (tier_indices, 0..) |idx, tier_i| {
            if (memory_layout[idx].size >= tier_page_sizes[tier_i]) region_count += 1;
        }

        const regions = try allocator.alloc(Region, region_count);
        errdefer allocator.free(regions);

        var created: usize = 0;
        errdefer {
            for (regions[0..created]) |*region| region.page_bitmap.deinit();
        }

        for (tier_indices, 0..) |idx, tier_i| {
            const info = memory_layout[idx];
            const region_page_size = tier_page_sizes[tier_i];
            if (info.size < region_page_size) continue;
            const page_count = info.size / region_page_size;
            regions[created] = .{
                .start_address = info.start_address,
                .page_count = page_count,
                .page_size = region_page_size,
                .page_bitmap = try std.DynamicBitSet.initEmpty(allocator, page_count),
            };
            log.debug("Process memory tier {d}: 0x{x} ({d} pages)", .{ created, info.start_address, page_count });
            created += 1;
        }

        return ProcessMemoryPool{
            .regions = regions,
            .memory_map = ProcessMemoryMap.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProcessMemoryPool) void {
        log.debug("Process memory pool deinitialization started...", .{});
        for (self.regions) |*region| region.page_bitmap.deinit();
        self.allocator.free(self.regions);
        var it = self.memory_map.iterator();
        while (it.next()) |process| {
            var next = process.value_ptr.pop();
            while (next) |node| {
                const entity: *ProcessMemoryEntity = @fieldParentPtr("node", node);
                next = process.value_ptr.pop();
                self.allocator.destroy(entity);
            }
        }
        self.memory_map.deinit();
    }

    fn region_for_addr(self: *ProcessMemoryPool, addr: usize) ?*Region {
        for (self.regions) |*region| {
            if (addr >= region.start_address and addr < region.start_address + region.page_count * region.page_size) {
                return region;
            }
        }
        return null;
    }

    fn get_next_free_slot(region: *Region, start_index: usize, pages_number: i32) !struct { usize, usize } {
        var start = start_index;
        var pages = pages_number - 1;
        while (start < region.page_count) {
            if (!region.page_bitmap.isSet(start)) {
                break;
            }

            start += 1;
        }

        if (start >= region.page_count) {
            return kernel.errno.ErrnoSet.OutOfMemory;
        }

        var end_index = start;
        while (end_index < region.page_count and pages != 0) {
            if (region.page_bitmap.isSet(end_index)) {
                return .{ start, end_index - 1 };
            }
            end_index += 1;
            pages -= 1;
        }

        if (end_index - start_index < @as(usize, @intCast(pages_number - 1))) {
            return kernel.errno.ErrnoSet.OutOfMemory;
        }

        if (end_index >= region.page_count or region.page_bitmap.isSet(end_index)) {
            return .{ start, end_index - 1 };
        }
        return .{ start, end_index };
    }

    fn slicify(ptr: [*]u8, len: usize) []u8 {
        return ptr[0..len];
    }

    pub fn allocate_pages(self: *ProcessMemoryPool, number_of_pages: i32, pid: c.pid_t) ?[]u8 {
        // Read+clear the heap tag up front so a failed allocation can't taint
        // the next (possibly loader) one.
        const source: AllocSource = if (self.tag_next_heap) .heap else .loader;
        self.tag_next_heap = false;
        if (number_of_pages <= 0) {
            return null;
        }
        // Bytes requested: callers count in page_size (the 256 B minimum grain).
        const requested_bytes = @as(usize, @intCast(number_of_pages)) * page_size;
        // Probe regions fast-first; the first region with a contiguous run wins.
        for (self.regions) |*region| {
            // Round the request up to THIS region's own page grain.
            const region_pages_usize = (requested_bytes + region.page_size - 1) / region.page_size;
            const region_pages: i32 = @intCast(region_pages_usize);
            var start_index: usize = 0;
            while (start_index < region.page_count) {
                const slot_start, const slot_end = get_next_free_slot(region, start_index, region_pages) catch break;
                if (slot_end - slot_start >= region_pages - 1) {
                    const end_index: usize = slot_start + region_pages_usize;
                    for (slot_start..end_index) |i| {
                        region.page_bitmap.set(i);
                    }
                    if (region.page_bitmap.count() > region.peak_used) {
                        region.peak_used = region.page_bitmap.count();
                    }
                    var list = self.memory_map.getOrPut(pid) catch {
                        for (slot_start..end_index) |i| region.page_bitmap.unset(i);
                        return null;
                    };
                    if (!list.found_existing) {
                        list.value_ptr.* = .{};
                    }
                    const entity = self.allocator.create(ProcessMemoryEntity) catch {
                        for (slot_start..end_index) |i| region.page_bitmap.unset(i);
                        return null;
                    };
                    entity.* = .{
                        .address = slicify(
                            @as([*]u8, @ptrFromInt(region.start_address + slot_start * region.page_size)),
                            region_pages_usize * region.page_size,
                        ),
                        .pid = pid,
                        .access = .{ .read = 1, .write = 1, .execute = 1 },
                        .source = source,
                        .node = .{},
                    };
                    list.value_ptr.append(&entity.node);
                    log.debug("Allocating {d} pages for {d} at 0x{x}", .{ number_of_pages, pid, @intFromPtr(entity.address.ptr) });
                    @memset(entity.address, 0);
                    return entity.address;
                } else {
                    start_index = slot_end + 1;
                }
            }
        }
        return null;
    }

    pub fn release_pages_for(self: *ProcessMemoryPool, pid: c.pid_t) void {
        const pages_before = self.get_used_size() / page_size;
        log.info("release_pages_for: pid={d} pages_before={d}", .{ pid, pages_before });
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            var pages_freed: usize = 0;
            var entity_count: usize = 0;
            var next = mapping.value_ptr.first;
            while (next) |entity_node| {
                const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
                if (self.region_for_addr(@intFromPtr(entity.address.ptr))) |region| {
                    const start_index = (@intFromPtr(entity.address.ptr) - region.start_address) / region.page_size;
                    const end_index = start_index + @as(usize, @intCast(entity.address.len)) / region.page_size;
                    const n_pages = end_index - start_index;
                    log.info("  entity[{d}]: addr=0x{x} pages={d}", .{ entity_count, @intFromPtr(entity.address.ptr), n_pages });
                    for (start_index..end_index) |index| {
                        region.page_bitmap.unset(index);
                    }
                    pages_freed += n_pages;
                }
                entity_count += 1;
                next = entity_node.next;
            }
            log.info("  total entities={d} pages_freed={d}", .{ entity_count, pages_freed });
            if (self.memory_map.getPtr(pid)) |*list| {
                var next_element = list.*.pop();
                while (next_element) |node| {
                    const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", node);
                    self.allocator.destroy(entity);
                    next_element = list.*.pop();
                }
            }
            _ = self.memory_map.remove(pid);
            log.info("release_pages_for: pid={d} pages_after={d}", .{ pid, self.get_used_size() / page_size });
        } else {
            log.warn("release_pages_for: pid={d} not found in memory_map", .{pid});
        }
    }

    pub fn free_pages(self: *ProcessMemoryPool, address: *anyopaque, number_of_pages: i32, pid: c.pid_t) void {
        log.debug("Releasing pages {d} at 0x{x} for pid: {d}", .{ number_of_pages, @intFromPtr(address), pid });
        const region = self.region_for_addr(@intFromPtr(address)) orelse return;
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            var next = mapping.value_ptr.first;
            while (next) |entity_node| {
                const entity: *ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
                if (@as(*anyopaque, entity.address.ptr) == address) {
                    _ = mapping.value_ptr.remove(entity_node);
                    self.allocator.destroy(entity);
                    break;
                }
                next = entity_node.next;
            }
            const start_index = (@intFromPtr(address) - region.start_address) / region.page_size;
            const region_pages = (@as(usize, @intCast(number_of_pages)) * page_size + region.page_size - 1) / region.page_size;
            const end_index = start_index + region_pages;
            for (start_index..end_index) |index| {
                region.page_bitmap.unset(index);
            }
        }
    }

    pub fn get_used_size(self: ProcessMemoryPool) usize {
        var used: usize = 0;
        for (self.regions) |region| {
            used += region.page_bitmap.count() * region.page_size;
        }
        return used;
    }

    /// Reset every region's peak-used high-water mark (perf diagnostics). Call at
    /// exec so a process's run window starts from a clean peak.
    pub fn reset_peaks(self: *ProcessMemoryPool) void {
        for (self.regions) |*region| region.peak_used = 0;
    }

    /// Peak used pages in a tier since the last reset_peaks (0=fast SRAM, 1=PSRAM).
    pub fn peak_used_pages(self: *const ProcessMemoryPool, region_index: usize) usize {
        if (region_index >= self.regions.len) return 0;
        return self.regions[region_index].peak_used;
    }

    /// Currently used (allocated) pages in a tier right now (0=fast SRAM, 1=PSRAM).
    /// Unlike peak_used_pages this is the live occupancy, used to report how much of
    /// a tier is already resident (e.g. the shell + libs) before a new exec allocates.
    pub fn used_pages(self: *const ProcessMemoryPool, region_index: usize) usize {
        if (region_index >= self.regions.len) return 0;
        return self.regions[region_index].page_bitmap.count();
    }

    /// Total pages currently owned by a single process across all tiers. Used to
    /// enforce a per-image heap cap (the YAFF heap_size profile): exec records a
    /// baseline after the image+stack are resident, then bounds further growth.
    pub fn used_pages_for(self: *const ProcessMemoryPool, pid: c.pid_t) usize {
        const mapping = self.memory_map.get(pid) orelse return 0;
        var pages: usize = 0;
        var next = mapping.first;
        while (next) |node| {
            const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", node);
            pages += entity.address.len / page_size;
            next = node.next;
        }
        return pages;
    }

    /// Tier index (0=fast SRAM, 1=PSRAM) backing `addr`, or null if unmanaged.
    fn region_index_for_addr(self: *const ProcessMemoryPool, addr: usize) ?usize {
        for (self.regions, 0..) |*region, idx| {
            if (addr >= region.start_address and addr < region.start_address + region.page_count * region.page_size) {
                return idx;
            }
        }
        return null;
    }

    /// Per-process, per-tier page-usage breakdown (perf diagnostics). Attributes
    /// the pool's live occupancy to each pid so per-process footprint reductions
    /// (e.g. shrinking toybox or tcc) are directly measurable: it emits one
    /// `[ERR][tprof] proc pid=<n> sram=<pages> psram=<pages> total=<pages>` line
    /// per live process. Pages are 4 KiB. Correlate pid with the `load`/`base`
    /// lines (which carry the executable path).
    pub fn dump_usage_by_pid(self: *const ProcessMemoryPool) void {
        var it = self.memory_map.iterator();
        while (it.next()) |entry| {
            var sram: usize = 0;
            var psram: usize = 0;
            // Heap profiling: libc malloc serves small allocs from 32 KiB bump
            // pools (MSETLEN) and large allocs (>=4 KiB) as page-aligned mmaps,
            // so count exact 32 KiB allocations as malloc pools and the rest
            // (image data/bss/got, 16 KiB stack, thunks) separately. Lets us see
            // how much of a process's pool footprint is reclaimable heap.
            // Report bytes: regions now use different page grains (SRAM 256 B,
            // PSRAM 4 KiB), so a single "pages" count would mix units.
            var heap_bytes: usize = 0; // user mmap/malloc (reducible)
            var loader_bytes: usize = 0; // image + stack + got + thunks (fixed)
            var next = entry.value_ptr.first;
            while (next) |node| {
                const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", node);
                const bytes = entity.address.len;
                switch (self.region_index_for_addr(@intFromPtr(entity.address.ptr)) orelse 1) {
                    0 => sram += bytes,
                    else => psram += bytes,
                }
                switch (entity.source) {
                    .heap => heap_bytes += bytes,
                    .loader => loader_bytes += bytes,
                }
                next = node.next;
            }
            if (sram + psram == 0) continue;
            perf.trace("proc pid={d} sram_b={d} psram_b={d} total_b={d} heap_b={d} loader_b={d}", .{ entry.key_ptr.*, sram, psram, sram + psram, heap_bytes, loader_bytes });
        }
    }

    /// Total pages in a tier (0=fast SRAM, 1=PSRAM).
    pub fn region_page_count(self: *const ProcessMemoryPool, region_index: usize) usize {
        if (region_index >= self.regions.len) return 0;
        return self.regions[region_index].page_count;
    }

    /// Sum of page counts across all tiers. Exposed mainly for diagnostics/tests.
    pub fn total_page_count(self: ProcessMemoryPool) usize {
        var total: usize = 0;
        for (self.regions) |region| {
            total += region.page_count;
        }
        return total;
    }

    /// Try to extend an existing allocation in-place by claiming free pages
    /// immediately after it. Returns the new total slice on success, null on failure.
    /// Extension never crosses a region boundary.
    pub fn try_extend_pages(self: *ProcessMemoryPool, address: *anyopaque, old_pages: i32, new_pages: i32, pid: c.pid_t) ?[]u8 {
        if (new_pages <= old_pages) return null;
        const addr_int = @intFromPtr(address);
        const region = self.region_for_addr(addr_int) orelse return null;

        // old/new_pages count in the 256 B grain; round to this region's grain.
        const old_region_pages = (@as(usize, @intCast(old_pages)) * page_size + region.page_size - 1) / region.page_size;
        const new_region_pages = (@as(usize, @intCast(new_pages)) * page_size + region.page_size - 1) / region.page_size;
        const start_index = (addr_int - region.start_address) / region.page_size;
        const old_end = start_index + old_region_pages;
        const new_end = start_index + new_region_pages;

        // Check that all extension pages are within bounds and free
        if (new_end > region.page_count) return null;
        for (old_end..new_end) |i| {
            if (region.page_bitmap.isSet(i)) return null;
        }

        // Mark extension pages as used
        for (old_end..new_end) |i| {
            region.page_bitmap.set(i);
        }

        // Update the entity in the memory map to reflect new size
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            var next = mapping.value_ptr.first;
            while (next) |entity_node| {
                const entity: *ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
                if (@as(*anyopaque, entity.address.ptr) == address) {
                    entity.address = slicify(
                        @as([*]u8, @ptrFromInt(addr_int)),
                        new_region_pages * region.page_size,
                    );
                    // Zero only the newly extended pages
                    const ext_start = old_region_pages * region.page_size;
                    @memset(entity.address[ext_start..], 0);
                    return entity.address;
                }
                next = entity_node.next;
            }
        }

        // Entity not found — shouldn't happen, undo bitmap changes
        for (old_end..new_end) |i| {
            region.page_bitmap.unset(i);
        }
        return null;
    }
};

test "ProcessMemoryPool.ShouldInitializeAndDeinitialize" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    try std.testing.expect(pool.regions.len > 0);
    try std.testing.expect(pool.total_page_count() > 0);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldAllocateSinglePage" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const pages = pool.allocate_pages(1, pid);

    try std.testing.expect(pages != null);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size), pages.?.len);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldAllocateMultiplePages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const num_pages = 4;
    const pages = pool.allocate_pages(num_pages, pid);

    try std.testing.expect(pages != null);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * num_pages), pages.?.len);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * num_pages), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldReturnNullForZeroPages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const pages = pool.allocate_pages(0, pid);

    try std.testing.expectEqual(null, pages);
}

test "ProcessMemoryPool.ShouldReturnNullForNegativePages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const pages = pool.allocate_pages(-5, pid);

    try std.testing.expectEqual(null, pages);
}

test "ProcessMemoryPool.ShouldAllocateForDifferentProcesses" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid1: c.pid_t = 1;
    const pid2: c.pid_t = 2;

    const pages1 = pool.allocate_pages(2, pid1);
    const pages2 = pool.allocate_pages(3, pid2);

    try std.testing.expect(pages1 != null);
    try std.testing.expect(pages2 != null);
    try std.testing.expect(@intFromPtr(pages1.?.ptr) != @intFromPtr(pages2.?.ptr));
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 5), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldFreePages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const num_pages = 3;
    const pages = pool.allocate_pages(num_pages, pid);

    try std.testing.expect(pages != null);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * num_pages), pool.get_used_size());

    pool.free_pages(pages.?.ptr, num_pages, pid);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldReleasePagesForProcess" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;

    _ = pool.allocate_pages(2, pid);
    _ = pool.allocate_pages(3, pid);
    _ = pool.allocate_pages(1, pid);

    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 6), pool.get_used_size());

    pool.release_pages_for(pid);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldReleaseOnlySpecificProcessPages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid1: c.pid_t = 1;
    const pid2: c.pid_t = 2;

    _ = pool.allocate_pages(2, pid1);
    _ = pool.allocate_pages(3, pid2);

    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 5), pool.get_used_size());

    pool.release_pages_for(pid1);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 3), pool.get_used_size());

    pool.release_pages_for(pid2);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldReuseFreedPages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;

    const pages1 = pool.allocate_pages(2, pid);
    try std.testing.expect(pages1 != null);
    const addr1 = @intFromPtr(pages1.?.ptr);

    pool.free_pages(pages1.?.ptr, 2, pid);

    const pages2 = pool.allocate_pages(2, pid);
    try std.testing.expect(pages2 != null);
    const addr2 = @intFromPtr(pages2.?.ptr);

    try std.testing.expectEqual(addr1, addr2);
}

test "ProcessMemoryPool.ShouldAllocateContiguousPages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const num_pages = 5;
    const pages = pool.allocate_pages(num_pages, pid);

    try std.testing.expect(pages != null);

    const start_addr = @intFromPtr(pages.?.ptr);
    const expected_size = ProcessMemoryPool.page_size * num_pages;

    try std.testing.expectEqual(expected_size, pages.?.len);

    // Verify every page address falls inside one (the same) backing region.
    const owning = pool.region_for_addr(start_addr);
    try std.testing.expect(owning != null);
    for (0..num_pages) |i| {
        const page_addr = start_addr + i * ProcessMemoryPool.page_size;
        try std.testing.expectEqual(owning, pool.region_for_addr(page_addr));
    }
}

test "ProcessMemoryPool.ShouldHandleFragmentation" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;

    const pages1 = pool.allocate_pages(2, pid);
    const pages2 = pool.allocate_pages(2, pid);
    const pages3 = pool.allocate_pages(2, pid);

    try std.testing.expect(pages1 != null);
    try std.testing.expect(pages2 != null);
    try std.testing.expect(pages3 != null);

    // Free middle allocation
    pool.free_pages(pages2.?.ptr, 2, pid);

    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 4), pool.get_used_size());

    // Should be able to allocate in the freed spot
    const pages4 = pool.allocate_pages(2, pid);
    try std.testing.expect(pages4 != null);
    try std.testing.expectEqual(@intFromPtr(pages2.?.ptr), @intFromPtr(pages4.?.ptr));
}

test "ProcessMemoryPool.ShouldHandleMultipleAllocationsForSameProcess" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 100;
    var allocations = try std.ArrayList([]u8).initCapacity(std.testing.allocator, 16);
    defer allocations.deinit(std.testing.allocator);

    for (0..5) |_| {
        const pages = pool.allocate_pages(1, pid);
        try std.testing.expect(pages != null);
        try allocations.append(std.testing.allocator, pages.?);
    }

    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 5), pool.get_used_size());

    pool.release_pages_for(pid);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldHandleNoAvailableMemory" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;

    // Allocations never span regions, and tiers use different page grains, so the
    // total page count mixes units. Size the request from the largest region's
    // byte capacity instead: a request larger (in bytes) than the biggest region
    // can never be satisfied by any single region, so it must fail.
    var largest_region_bytes: usize = 0;
    for (pool.regions) |region| {
        largest_region_bytes = @max(largest_region_bytes, region.page_count * region.page_size);
    }
    const pages_exceeding_any_region: i32 = @intCast(largest_region_bytes / ProcessMemoryPool.page_size + 1);
    const pages = pool.allocate_pages(pages_exceeding_any_region, pid);
    try std.testing.expectEqual(@as(?[]u8, null), pages);
}

test "ProcessMemoryPool.ShouldReleaseNonExistentProcessSafely" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 999;

    // Should not crash
    pool.release_pages_for(pid);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldFreeNonExistentPagesSafely" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const pages = pool.allocate_pages(2, pid);
    try std.testing.expect(pages != null);

    // Try to free with wrong address
    const fake_addr: *anyopaque = @ptrFromInt(0xDEADBEEF);
    pool.free_pages(fake_addr, 2, pid);

    // Original allocation should still be tracked
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 2), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldPreferFirstRegion" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const pages = pool.allocate_pages(1, pid);
    try std.testing.expect(pages != null);

    // A small allocation must land in the fast (first) region.
    const addr = @intFromPtr(pages.?.ptr);
    const first = &pool.regions[0];
    try std.testing.expect(addr >= first.start_address);
    try std.testing.expect(addr < first.start_address + first.page_count * ProcessMemoryPool.page_size);
}

test "ProcessMemoryPool.ShouldFallBackToSecondRegionWhenFirstFull" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    if (pool.regions.len < 2) return error.SkipZigTest;

    const pid: c.pid_t = 1;

    // Fill the entire first region.
    const first_pages: i32 = @intCast(pool.regions[0].page_count);
    const filler = pool.allocate_pages(first_pages, pid);
    try std.testing.expect(filler != null);

    // The next allocation cannot fit in region 0, so it must spill to region 1.
    const spill = pool.allocate_pages(1, pid);
    try std.testing.expect(spill != null);

    const addr = @intFromPtr(spill.?.ptr);
    const second = &pool.regions[1];
    try std.testing.expect(addr >= second.start_address);
    try std.testing.expect(addr < second.start_address + second.page_count * ProcessMemoryPool.page_size);
}
