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
/// Report frees that cannot be matched to a live mapping of the freeing
/// process, or that hand back more bytes than were allocated. Both mark pages
/// free while another owner is still using them, which surfaces much later as
/// one process finding another's data in its memory. Cheap (it reuses the walk
/// free_pages already does) but it does emit serial output, so it is opt-in.
const validate_frees = false;

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
        // Set pages in page_bitmap, maintained by mark_used/mark_free. The
        // bitmap remains the truth; this is a running total so occupancy is O(1)
        // instead of a popcount over the whole bitmap. It used to be counted
        // twice per allocation just to update peak_used.
        used_pages: usize = 0,
        // Lower bound on the index of the first free page. The allocator scans
        // from here rather than from zero: a region whose low pages are held by
        // the resident shell and libraries would otherwise re-walk that whole
        // occupied prefix on every allocation, and a tcc compile makes hundreds
        // of them (libc sends every alloc >= MSETMAX straight to mmap). Only a
        // bound, never a claim about a specific page — mark_free lowers it, the
        // scan raises it — so allocation still picks exactly the first-fit slot
        // a scan from zero would have picked.
        first_free_hint: usize = 0,
    };

    /// Claim `[from, to)` in `region`. Counts only pages that actually change
    /// state, so a caller that overlaps an existing allocation cannot skew
    /// used_pages away from the bitmap's popcount.
    fn mark_used(region: *Region, from: usize, to: usize) void {
        for (from..to) |index| {
            if (!region.page_bitmap.isSet(index)) {
                region.page_bitmap.set(index);
                region.used_pages += 1;
            }
        }
    }

    /// Release `[from, to)` in `region`. Same transition-counting as mark_used:
    /// free_pages will happily unset a range it never allocated (a bad address
    /// inside a region reaches it), and that must not drive the count negative.
    fn mark_free(region: *Region, from: usize, to: usize) void {
        for (from..to) |index| {
            if (region.page_bitmap.isSet(index)) {
                region.page_bitmap.unset(index);
                region.used_pages -= 1;
            }
        }
        if (from < region.first_free_hint) {
            region.first_free_hint = from;
        }
    }

    /// Lowest index in `[from, limit)` starting `pages` consecutive free pages,
    /// or null. Scans each candidate window from its top: a used page at offset
    /// k rules out every start below k+1, so the next candidate resumes there
    /// instead of retesting the window a page at a time.
    fn find_free_run(region: *const Region, pages: usize, from: usize, limit: usize) ?usize {
        if (pages == 0) return null;
        var start = from;
        while (start + pages <= limit) {
            var offset = pages;
            var blocked: ?usize = null;
            while (offset > 0) {
                offset -= 1;
                if (region.page_bitmap.isSet(start + offset)) {
                    blocked = start + offset;
                    break;
                }
            }
            if (blocked) |index| {
                start = index + 1;
            } else {
                return start;
            }
        }
        return null;
    }

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
        // Phase stamps (compiled out unless profiling): mmap costs 407 us a
        // call and this is where it goes. See perf.PoolPhase.
        const t_scan = if (perf.enabled) perf.read_cycles() else 0;
        // Probe regions fast-first; the first region with a contiguous run wins.
        for (self.regions, 0..) |*region, tier| {
            // Round the request up to THIS region's own page grain.
            const region_pages_usize = (requested_bytes + region.page_size - 1) / region.page_size;
            // A region without enough free pages anywhere cannot have them
            // contiguously either, so reject it before walking its bitmap. This
            // is the common case once fast SRAM fills and every subsequent
            // allocation is spilling to PSRAM.
            if (region.used_pages + region_pages_usize > region.page_count) continue;
            // Everything below the hint is occupied, so no run can start there
            // and skipping it costs nothing in placement: this still returns the
            // same slot a scan from page zero would have.
            while (region.first_free_hint < region.page_count and region.page_bitmap.isSet(region.first_free_hint)) {
                region.first_free_hint += 1;
            }
            const slot_start = find_free_run(region, region_pages_usize, region.first_free_hint, region.page_count) orelse continue;
            const t_mark = if (perf.enabled) perf.read_cycles() else 0;
            perf.pool_record(.scan, t_mark -% t_scan);
            const end_index: usize = slot_start + region_pages_usize;
            // A run must not already be covered by a live mapping. The bitmap is
            // supposed to guarantee that, so this checks the bitmap against the
            // entity list rather than trusting it: if the two ever disagree, a
            // page is handed to a second owner and the first one's data is
            // silently overwritten -- which is the fault being chased here (one
            // process finding a foreign value in its .bss).
            if (validate_frees) {
                const run_start = region.start_address + slot_start * region.page_size;
                const run_end = run_start + region_pages_usize * region.page_size;
                var it = self.memory_map.iterator();
                outer: while (it.next()) |kv| {
                    var node = kv.value_ptr.first;
                    while (node) |n| : (node = n.next) {
                        const e: *const ProcessMemoryEntity = @fieldParentPtr("node", n);
                        const e_start = @intFromPtr(e.address.ptr);
                        const e_end = e_start + e.address.len;
                        if (run_start < e_end and e_start < run_end) {
                            perf.trace("overlap pid={d} run=0x{x}..0x{x} owner_pid={d} live=0x{x}..0x{x}", .{
                                pid, run_start, run_end, e.pid, e_start, e_end,
                            });
                            break :outer;
                        }
                    }
                }
            }
            mark_used(region, slot_start, end_index);
            if (region.used_pages > region.peak_used) {
                region.peak_used = region.used_pages;
            }
            const t_book = if (perf.enabled) perf.read_cycles() else 0;
            perf.pool_record(.mark, t_book -% t_mark);
            var list = self.memory_map.getOrPut(pid) catch {
                mark_free(region, slot_start, end_index);
                return null;
            };
            if (!list.found_existing) {
                list.value_ptr.* = .{};
            }
            const entity = self.allocator.create(ProcessMemoryEntity) catch {
                mark_free(region, slot_start, end_index);
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
            // Pages are recycled between processes, so they must be cleared
            // before handout or one process's memory leaks into the next. Note
            // this guarantee reaches only callers of allocate_pages directly
            // (the mmap path): a caller going through std.mem.Allocator gets its
            // fresh allocation overwritten with `undefined` on the way out
            // (Allocator.allocBytesWithAlignment), which is 0xAA in a
            // safety-enabled build. Anything downstream of the Allocator
            // interface — the dynamic loader's image block, notably — cannot
            // skip its own zeroing on the strength of this memset.
            const t_clear = if (perf.enabled) perf.read_cycles() else 0;
            perf.pool_record(.book, t_clear -% t_book);
            // A board may know a cheaper route to zeroed pages than a plain
            // memset -- on the rp2350 the PSRAM tier is cached write-allocate,
            // so the obvious one moves twice the bytes it needs to and evicts
            // the running process's code doing it. Boards that do not say
            // otherwise get the memset, resolved at compile time.
            memory.zero_pages(entity.address);
            if (perf.enabled) {
                perf.pool_clear(tier, perf.read_cycles() -% t_clear, entity.address.len);
                perf.pool_alloc(region_pages_usize, entity.address.len, tier);
            }
            return entity.address;
        }
        return null;
    }

    pub fn release_pages_for(self: *ProcessMemoryPool, pid: c.pid_t) void {
        log.debug("release_pages_for: pid={d} pages_before={d}", .{ pid, self.get_used_size() / page_size });
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
                    log.debug("  entity[{d}]: addr=0x{x} pages={d}", .{ entity_count, @intFromPtr(entity.address.ptr), n_pages });
                    mark_free(region, start_index, end_index);
                    pages_freed += n_pages;
                }
                entity_count += 1;
                next = entity_node.next;
            }
            log.debug("  total entities={d} pages_freed={d}", .{ entity_count, pages_freed });
            if (self.memory_map.getPtr(pid)) |*list| {
                var next_element = list.*.pop();
                while (next_element) |node| {
                    const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", node);
                    self.allocator.destroy(entity);
                    next_element = list.*.pop();
                }
            }
            _ = self.memory_map.remove(pid);
            log.debug("release_pages_for: pid={d} pages_after={d}", .{ pid, self.get_used_size() / page_size });
        } else {
            log.warn("release_pages_for: pid={d} not found in memory_map", .{pid});
        }
    }

    pub fn free_pages(self: *ProcessMemoryPool, address: *anyopaque, number_of_pages: i32, pid: c.pid_t) void {
        log.debug("Releasing pages {d} at 0x{x} for pid: {d}", .{ number_of_pages, @intFromPtr(address), pid });
        const region = self.region_for_addr(@intFromPtr(address)) orelse return;
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            // The list walk below is linear in a process's live mappings, so it
            // is timed separately from the bitmap work: if munmap is slow, the
            // two answers are "index the mappings" and "the bitmap", and they
            // are different jobs.
            const t_lookup = if (perf.enabled) perf.read_cycles() else 0;
            var next = mapping.value_ptr.first;
            var matched_bytes: usize = 0;
            var found = false;
            while (next) |entity_node| {
                const entity: *ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
                if (@as(*anyopaque, entity.address.ptr) == address) {
                    matched_bytes = entity.address.len;
                    found = true;
                    _ = mapping.value_ptr.remove(entity_node);
                    self.allocator.destroy(entity);
                    break;
                }
                next = entity_node.next;
            }
            // mark_free below runs whatever the walk found, using the *caller's*
            // length rather than the entity's. Two ways that corrupts another
            // owner's memory: freeing an address this pid never allocated, and
            // freeing more bytes than were allocated -- either marks pages free
            // while they are still live, and the next allocation hands them to
            // somebody else. Report both; this is diagnosing a fault where one
            // process's .bss came back holding another's data.
            if (validate_frees) {
                const asked_bytes = @as(usize, @intCast(number_of_pages)) * page_size;
                if (!found) {
                    perf.trace("badfree pid={d} addr=0x{x} bytes={d} reason=unowned", .{
                        pid, @intFromPtr(address), asked_bytes,
                    });
                } else if (asked_bytes > matched_bytes) {
                    perf.trace("badfree pid={d} addr=0x{x} bytes={d} owned={d} reason=oversized", .{
                        pid, @intFromPtr(address), asked_bytes, matched_bytes,
                    });
                }
            }
            const t_mark = if (perf.enabled) perf.read_cycles() else 0;
            perf.pool_record(.free_lookup, t_mark -% t_lookup);
            const start_index = (@intFromPtr(address) - region.start_address) / region.page_size;
            const region_pages = (@as(usize, @intCast(number_of_pages)) * page_size + region.page_size - 1) / region.page_size;
            const end_index = start_index + region_pages;
            mark_free(region, start_index, end_index);
            if (perf.enabled) {
                perf.pool_record(.free_mark, perf.read_cycles() -% t_mark);
                perf.pool_free();
            }
        }
    }

    /// True if `address` is the base of a live mapping of at least `bytes`
    /// belonging to `pid`.
    ///
    /// The reuse cache in ProcessPageAllocator parks whatever munmap hands it,
    /// and hands it back to a later mmap without clearing. Without this check a
    /// process could munmap an address it never owned -- one inside another
    /// process's region -- and then mmap it straight back with the contents
    /// intact. free_pages tolerates such an address by ignoring it; the cache
    /// must reject it.
    pub fn owns_mapping(self: *const ProcessMemoryPool, pid: c.pid_t, address: *const anyopaque, bytes: usize) bool {
        const mapping = self.memory_map.getPtr(pid) orelse return false;
        var next = mapping.first;
        while (next) |entity_node| {
            const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
            if (@as(*const anyopaque, entity.address.ptr) == address) {
                return entity.address.len >= bytes;
            }
            next = entity_node.next;
        }
        return false;
    }

    pub fn get_used_size(self: ProcessMemoryPool) usize {
        var used: usize = 0;
        for (self.regions) |region| {
            used += region.used_pages * region.page_size;
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
        return self.regions[region_index].used_pages;
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
        mark_used(region, old_end, new_end);
        if (region.used_pages > region.peak_used) {
            region.peak_used = region.used_pages;
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
        mark_free(region, old_end, new_end);
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

/// The maintained per-region counter has to stay exactly the bitmap's popcount,
/// or /proc/meminfo and the heap cap both drift. Checked after every mutating
/// path rather than trusting the arithmetic.
fn expect_counts_match_bitmap(pool: *const ProcessMemoryPool) !void {
    for (pool.regions) |*region| {
        try std.testing.expectEqual(region.page_bitmap.count(), region.used_pages);
    }
}

/// The hint is only ever a lower bound; a page below it must never be free, or
/// allocation would skip a slot that first-fit should have taken.
fn expect_hint_is_lower_bound(pool: *const ProcessMemoryPool) !void {
    for (pool.regions) |*region| {
        try std.testing.expect(region.first_free_hint <= region.page_count);
        for (0..region.first_free_hint) |index| {
            try std.testing.expect(region.page_bitmap.isSet(index));
        }
    }
}

test "ProcessMemoryPool.UsedCountTracksBitmapAcrossAllocAndFree" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 3;
    try expect_counts_match_bitmap(&pool);

    const a = pool.allocate_pages(3, pid).?;
    try expect_counts_match_bitmap(&pool);
    const b = pool.allocate_pages(5, pid).?;
    try expect_counts_match_bitmap(&pool);

    pool.free_pages(a.ptr, 3, pid);
    try expect_counts_match_bitmap(&pool);

    // Freeing the same range twice must not drive the counter below the bitmap:
    // free_pages clears the range whether or not it still owns it.
    pool.free_pages(a.ptr, 3, pid);
    try expect_counts_match_bitmap(&pool);

    _ = b;
    pool.release_pages_for(pid);
    try expect_counts_match_bitmap(&pool);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.FreeHintStaysALowerBound" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 4;
    const first = pool.allocate_pages(2, pid).?;
    const second = pool.allocate_pages(2, pid).?;
    const third = pool.allocate_pages(2, pid).?;
    try expect_hint_is_lower_bound(&pool);

    // Punch a hole in the middle: the hint has to fall back to it, otherwise the
    // next allocation would allocate past the hole and first-fit reuse is lost.
    pool.free_pages(second.ptr, 2, pid);
    try expect_hint_is_lower_bound(&pool);

    const refill = pool.allocate_pages(2, pid).?;
    try std.testing.expectEqual(@intFromPtr(second.ptr), @intFromPtr(refill.ptr));
    try expect_hint_is_lower_bound(&pool);
    try expect_counts_match_bitmap(&pool);

    _ = first;
    _ = third;
}

test "ProcessMemoryPool.AllocatesFirstFitAcrossAHoleTooSmallForTheRequest" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 5;
    const one = pool.allocate_pages(1, pid).?;
    const divider = pool.allocate_pages(1, pid).?;
    const two = pool.allocate_pages(4, pid).?;
    const three = pool.allocate_pages(1, pid).?;

    // A 1-page hole at the front, a still-held page keeping it separate, then a
    // 4-page hole. A 4-page request must skip the front hole and land in the
    // second; a later 1-page request must still find the front hole, which is
    // what proves the hint never advanced past it.
    pool.free_pages(one.ptr, 1, pid);
    pool.free_pages(two.ptr, 4, pid);
    _ = divider;

    const big = pool.allocate_pages(4, pid).?;
    try std.testing.expectEqual(@intFromPtr(two.ptr), @intFromPtr(big.ptr));

    const small = pool.allocate_pages(1, pid).?;
    try std.testing.expectEqual(@intFromPtr(one.ptr), @intFromPtr(small.ptr));

    try expect_hint_is_lower_bound(&pool);
    try expect_counts_match_bitmap(&pool);
    _ = three;
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
