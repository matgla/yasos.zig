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

const config = @import("config");
const std = @import("std");

const memory = @import("hal").memory;
const c = @import("libc_imports").c;

const perf = @import("../../interrupts/perf_profile.zig");
const vfmt = @import("../../vfmt.zig");
const locks = @import("../../sync/locks.zig");
const slow_heap = @import("kernel_slow_heap.zig");

/// Rank 80, a leaf, `spin_irq` rather than a sleeping mutex because
/// `release_pages_for` is reached from PendSV. Affordable only because
/// `allocate_pages` clears its pages outside this lock; what is left under it is
/// a bitmap scan and a hashmap insert.
///
/// The scalar readers deliberately do not take it -- they feed /proc/meminfo,
/// where a snapshot one allocation stale is fine. Every reader that walks
/// `memory_map` does, since a concurrent insert can rehash it underneath.
// record_run grows the pid's mapping list (a hash map) and allocates from the
// kernel heap under this lock, on the calling process's stack: an exec whose
// stack had 430 bytes left at the lock overflowed inside the kernel malloc with
// interrupts masked (user_fault_test's stack sweep, the vfork + execv row) --
// a kernel panic, where too little stack before the lock is just a kill.
var pagepool_lock: locks.Ranked(.pagepool) = .{ .stack_needed = 1024 };

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
///
/// The overlap arm is NOT cheap: it walks every live mapping of every process on
/// every allocation, with `pagepool_lock` held and interrupts masked. Turn it on
/// for a diagnostic run, not for a timing one -- it perturbs exactly the
/// windows this kind of bug hides in. It reports through `log.err` rather than
/// `perf.trace` so it works on a build without profiling enabled, which is every
/// board build.
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
    /// `cache` is the dynamic loader's relocated-image cache (yasld
    /// template.zig): memory that is only worth having while nobody else wants
    /// it, so it fills the pool from the slow end and gives way on demand --
    /// see `reclaim_hook`.
    /// `heap_top`: a short-lived heap block, taken from the top of the slowest region down
    /// (MAP_TOP), so that what comes and goes stays apart from what grows up from the bottom.
    pub const AllocSource = enum { loader, loader_slow, heap, heap_slow, heap_fast, heap_top, cache };

    /// Asked to free about `bytes` of reclaimable memory when an allocation
    /// finds no room; returns how much it freed, 0 when it has nothing left.
    /// Called without `pagepool_lock` -- what it frees comes back through
    /// `free_pages` -- and from whatever context the failing allocation ran in.
    pub var reclaim_hook: ?*const fn (bytes: usize) usize = null;
    /// Asked, after `reclaim_hook` has nothing left, to swap a waiting process
    /// out to make room for about `bytes` (process_manager.zig); returns what
    /// it freed.  Only for a process's own heap allocations, which come from
    /// its mmap with no lock held -- never the loader's, which reads the
    /// executable through the very filesystem a swap file is on.
    pub var swap_hook: ?*const fn (bytes: usize) usize = null;
    /// Set by reading /proc/swapnext: the next heap allocation calls
    /// `swap_hook` first, as one finding the pool full would. For tests.
    pub var force_swap_once: bool = false;

    const ProcessMemoryEntity = struct {
        address: []u8,
        pid: c.pid_t,
        access: AccessType,
        source: AllocSource,
        node: std.DoublyLinkedList.Node,
        /// Where `address`'s bytes are while the run is swapped out
        /// (`swap_out`): its pages are free then, and the entity only remembers
        /// which addresses the process expects them back at.
        swap_slot: u32 = no_swap_slot,
        /// A resident run's copy still on swap from its last swap-in, and the
        /// hash of the bytes it holds: the next swap-out of an unchanged run
        /// reuses it instead of writing (`swap_out`). Dropped whenever the run
        /// is freed, resized or reaped, so `kept_slot` always covers exactly
        /// `address.len` bytes.
        kept_slot: u32 = no_swap_slot,
        // align(4): an 8-aligned field would make the entity 8-aligned, and
        // every @fieldParentPtr from its list node an alignment increase.
        kept_hash: u64 align(4) = 0,

        fn swapped(self: *const ProcessMemoryEntity) bool {
            return self.swap_slot != no_swap_slot;
        }

        fn kept(self: *const ProcessMemoryEntity) bool {
            return self.kept_slot != no_swap_slot;
        }
    };

    /// What a run's swap copy is checked against. A false match would bring
    /// stale bytes back, so a 64-bit hash, not a checksum; it costs a read of
    /// the run, against writing it to the card.
    fn run_hash(data: []const u8) u64 {
        return std.hash.XxHash64.hash(0x5759_4150, data);
    }

    /// Give back `entity`'s kept copy, if it has one. `pagepool_lock` held
    /// or not: `drop` is safe either way.
    fn drop_kept(entity: *ProcessMemoryEntity) void {
        if (!entity.kept()) return;
        if (swap_io) |io| io.drop(io.ctx, entity.kept_slot, entity.address.len);
        entity.kept_slot = no_swap_slot;
    }

    /// Runs (and bytes) written out since boot, and swap-outs that found an
    /// unchanged copy on swap and wrote nothing. Under `pagepool_lock`.
    pub var swap_written_runs: usize = 0;
    pub var swap_written_bytes: u64 = 0;
    pub var swap_reused_runs: usize = 0;
    pub var swap_reused_bytes: u64 = 0;
    const no_swap_slot = std.math.maxInt(u32);

    /// Where a swapped-out run's bytes go: kernel/memory/swap.zig on a board, a
    /// buffer in the tests.  `store` and `load` may sleep and are called without
    /// `pagepool_lock`; `drop` must not, because `release_pages_for` holds it.
    pub const SwapIo = struct {
        ctx: *anyopaque,
        /// Keep `data`; returns what `load` and `drop` take.
        store: *const fn (ctx: *anyopaque, data: []const u8) anyerror!u32,
        load: *const fn (ctx: *anyopaque, slot: u32, data: []u8) anyerror!void,
        drop: *const fn (ctx: *anyopaque, slot: u32, bytes: usize) void,
    };
    /// Set once a swap device is active.
    pub var swap_io: ?SwapIo = null;
    const ProcessMemoryList = std.DoublyLinkedList;
    const ProcessMemoryMap = @import("yasld").IntegerHashMap(c.pid_t, ProcessMemoryList);

    // A single contiguous backing region with its own page bitmap. Regions are
    // probed in order, so earlier (faster) regions are preferred.
    const Region = struct {
        start_address: usize,
        page_count: usize,
        // Allocation grain for THIS region (bytes). May differ per tier.
        page_size: usize,
        page_bitmap: std.DynamicBitSet,
        // Who freed each page last (see `owner_tag`), so a process's next mapping
        // need not clear what only it ever wrote. Slow tier only: that is where
        // the clear is expensive and the page count small.
        last_owner: ?[]u8 = null,
        // Pages a process on its way back from swap already holds (`owner_tag`
        // of its pid, 0 for none); see `claim_swapped_pages`. Allocated at the
        // first swap-in that has to wait.
        claimed_by: ?[]u8 = null,
        // Pages such a process is still waiting for: `mark_free` hands them to
        // it the moment their holder lets go, instead of to the next first fit.
        wanted_by: ?[]u8 = null,
        // Pages a swapped-out process left behind and will need again, at these
        // addresses (`owner_tag` of its pid): handed out last. See `reserve_pages`.
        lent_by: ?[]u8 = null,
        lent_pages: usize = 0,
        // High-water mark of used pages in this region since the last reset.
        // Diagnostic only (perf profiling): lets us see whether a process spilled
        // out of fast SRAM into slow PSRAM during a run.
        peak_used: usize = 0,
        // The same high-water mark over a window the observer chooses. `peak_used`
        // is reset at every exec, so it describes the last process a test
        // spawned rather than the test; this one is cleared only on request
        // (`/proc/mempeak`), so a caller can bracket a whole test with it.
        watermark_used: usize = 0,
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

    const MaskInt = std.bit_set.Dynamic.MaskInt;
    const bits_per_word = @bitSizeOf(MaskInt);

    /// Ones in bits `[lo, hi)` of a single bitmap word. Both shifts stay in
    /// range by construction (`0 <= lo < hi <= bits_per_word`): `hi` is
    /// bits_per_word exactly when the word is fully covered, which shifts by
    /// zero, never by the word size.
    fn wordRangeMask(lo: usize, hi: usize) MaskInt {
        const ones: MaskInt = ~@as(MaskInt, 0);
        return (ones << @intCast(lo)) & (ones >> @intCast(bits_per_word - hi));
    }

    /// Population count of one bitmap word. Hand-rolled rather than @popCount
    /// because on this target @popCount survives Zig's C backend as a
    /// `__builtin_popcount` call, and tcc lowers that to a call into
    /// `__popcountsi2` -- a per-word function call in the allocator's hottest
    /// loop. This SWAR sequence is the same arithmetic tcc's own runtime and
    /// LLVM use for the builtin, and costs ~12 inline ALU ops, word size
    /// independent (the divisor constants are the classic 3/5/17/255 ones).
    /// The final multiply must wrap: the byte sums carry into the top byte
    /// only mod 2^bits_per_word, and Zig's checked `*` would trap on that.
    fn popcountWord(x: MaskInt) usize {
        const ones: MaskInt = ~@as(MaskInt, 0);
        const v1 = x - ((x >> 1) & (ones / 3));
        const v2 = (v1 & (ones / 5)) + ((v1 >> 2) & (ones / 5));
        const v3 = (v2 + (v2 >> 4)) & (ones / 17);
        return @as(usize, v3 *% (ones / 255)) >> (bits_per_word - 8);
    }

    /// Flip `[from, to)` in `region`'s bitmap (clamped to the region, since
    /// free_pages tolerates caller lengths that run past the region end) and
    /// return how many pages actually changed state. One word per iteration:
    /// the masks pointer is read once, and `used_pages` is committed by the
    /// caller in a single store -- a page-at-a-time loop re-read the nested
    /// pointers and bumped the counter in memory for every page (6.2% of a
    /// warm launch, kernel-page-bitmap-per-page-work.md).
    fn markRange(region: *Region, from: usize, to: usize, comptime used: bool) usize {
        const masks = region.page_bitmap.unmanaged.masks;
        const end = @min(to, region.page_count);
        if (from >= end) return 0;
        const first_word = from / bits_per_word;
        const last_word = (end - 1) / bits_per_word;
        var transitions: usize = 0;
        var w = first_word;
        while (w <= last_word) : (w += 1) {
            const lo = if (w == first_word) from % bits_per_word else 0;
            const hi = if (w == last_word) (end - 1) % bits_per_word + 1 else bits_per_word;
            const mask = wordRangeMask(lo, hi);
            const old = masks[w];
            const new = if (used) old | mask else old & ~mask;
            if (new != old) {
                masks[w] = new;
                // Most claims touch a single page: the changed bits are then
                // exactly one, no matter how wide the mask word is.
                transitions += if (mask & (mask -% 1) == 0) 1 else popcountWord(old ^ new);
            }
        }
        return transitions;
    }

    /// Claim `[from, to)` in `region`. Counts only pages that actually change
    /// state, so a caller that overlaps an existing allocation cannot skew
    /// used_pages away from the bitmap's popcount.
    fn mark_used(region: *Region, from: usize, to: usize) void {
        // Bitmap surgery is only ever legal with the pool held. The assert is
        // the phase-3 completion item: it catches a caller that was *believed*
        // to hold the lock, which no amount of review reliably does.
        pagepool_lock.assert_held();
        region.used_pages += markRange(region, from, to, true);
    }

    /// Release `[from, to)` in `region`. Same transition-counting as mark_used:
    /// free_pages will happily unset a range it never allocated (a bad address
    /// inside a region reaches it), and that must not drive the count negative.
    fn mark_free(region: *Region, from: usize, to: usize) void {
        pagepool_lock.assert_held();
        region.used_pages -= markRange(region, from, to, false);
        if (from < region.first_free_hint) {
            region.first_free_hint = from;
        }
        // A page a process coming back from swap is waiting for goes straight to
        // it (see `claim_swapped_pages`).
        const wants = region.wanted_by orelse return;
        const held = region.claimed_by orelse return;
        var page = from;
        while (page < to) : (page += 1) {
            if (wants[page] == 0 or held[page] != 0) continue;
            held[page] = wants[page];
            region.used_pages += markRange(region, page, page + 1, true);
        }
    }

    inline fn advance_free_hint(region: *Region) usize {
        const masks = region.page_bitmap.unmanaged.masks;
        const page_count = region.page_count;
        var hint = region.first_free_hint;
        while (hint < page_count and (masks[hint / bits_per_word] & (@as(MaskInt, 1) << @intCast(hint % bits_per_word))) != 0) {
            hint += 1;
        }
        region.first_free_hint = hint;
        return hint;
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

    /// Highest index starting `pages` consecutive free pages, or null: `find_free_run` from the top.
    /// The lowest used page of a candidate window rules out every start above it minus `pages`.
    fn find_free_run_top(region: *const Region, pages: usize) ?usize {
        if (pages == 0 or pages > region.page_count) return null;
        var start = region.page_count - pages;
        while (true) {
            var offset: usize = 0;
            var blocked: ?usize = null;
            while (offset < pages) : (offset += 1) {
                if (region.page_bitmap.isSet(start + offset)) {
                    blocked = start + offset;
                    break;
                }
            }
            const index = blocked orelse return start;
            if (index < pages) return null;
            start = index - pages;
        }
    }

    regions: []Region,
    memory_map: ProcessMemoryMap,
    /// Hand a swapped-out process's pages out last (see `reserve_pages`). Off in
    /// the tests that need something to land on them.
    avoid_lent: bool = true,
    /// Pids whose image asked for slow memory: what they allocate without a
    /// stated tier starts at the slow end. See `set_prefers_slow`.
    /// Plain words: StaticBitSet's accessors take the set by value, 256 bytes copied
    /// to the stack of every allocation.
    slow_pids: [(config.process.max_pid_value + 31) / 32]u32 = @splat(0),
    // this allocator is used to keep track of the memory allocated for the process inside the kernel
    allocator: std.mem.Allocator,
    // Set by the user-mmap path immediately before allocate_pages so the next
    // allocation is tagged .heap; the loader path leaves it false (.loader).
    // Safe because mmap serializes via block_context_switch and exec is single
    // threaded. Profiling diagnostic only.

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

        // One byte per PSRAM page, read when a run is handed out, which already means
        // clearing it. The bitmaps stay in SRAM: every allocation scans them.
        const owners_allocator = slow_heap.allocator_or(allocator);

        const regions = try allocator.alloc(Region, region_count);
        errdefer allocator.free(regions);

        var created: usize = 0;
        errdefer {
            for (regions[0..created]) |*region| {
                region.page_bitmap.deinit();
                if (region.last_owner) |owners| owners_allocator.free(owners);
            }
        }

        for (tier_indices, 0..) |idx, tier_i| {
            const info = memory_layout[idx];
            const region_page_size = tier_page_sizes[tier_i];
            if (info.size < region_page_size) continue;
            const page_count = info.size / region_page_size;
            const owners: ?[]u8 = if (tier_i == tier_indices.len - 1) try owners_allocator.alloc(u8, page_count) else null;
            errdefer if (owners) |o| owners_allocator.free(o);
            if (owners) |o| @memset(o, 0);
            regions[created] = .{
                .start_address = info.start_address,
                .page_count = page_count,
                .page_size = region_page_size,
                .page_bitmap = try std.DynamicBitSet.initEmpty(allocator, page_count),
                .last_owner = owners,
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
        for (self.regions) |*region| {
            region.page_bitmap.deinit();
            if (region.last_owner) |owners| slow_heap.allocator_or(self.allocator).free(owners);
            if (region.claimed_by) |claims| slow_heap.allocator_or(self.allocator).free(claims);
            if (region.wanted_by) |wants| slow_heap.allocator_or(self.allocator).free(wants);
            if (region.lent_by) |lent| slow_heap.allocator_or(self.allocator).free(lent);
        }
        self.allocator.free(self.regions);
        var it = self.memory_map.iterator();
        while (it.next()) |process| {
            var next = process.value_ptr.pop();
            while (next) |node| {
                const entity: *ProcessMemoryEntity = @fieldParentPtr("node", node);
                next = process.value_ptr.pop();
                drop_kept(entity);
                if (entity.swapped()) {
                    if (swap_io) |io| io.drop(io.ctx, entity.swap_slot, entity.address.len);
                }
                slow_heap.allocator_or(self.allocator).destroy(entity);
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

    /// A run of pages taken out of the bitmap but not yet handed to anyone.
    const Reserved = struct {
        address: []u8,
        /// Region index, for the per-tier clear accounting.
        tier: usize,
        /// Pages in *that region's* grain, which is not the caller's grain.
        region_pages: usize,
    };

    pub fn allocate_pages(self: *ProcessMemoryPool, number_of_pages: i32, pid: c.pid_t) ?[]u8 {
        return self.allocate_pages_from(number_of_pages, pid, .loader);
    }

    /// `allocate_pages` naming the accounting bucket explicitly, rather than the
    /// one-shot flag on the pool this replaced -- that was a global handshake
    /// that only held while nothing else could allocate in between.
    pub fn allocate_pages_from(self: *ProcessMemoryPool, number_of_pages: i32, pid: c.pid_t, source: AllocSource) ?[]u8 {
        return self.allocate_pages_cleared(number_of_pages, pid, source, false);
    }

    /// `may_keep_own`: the caller does not need zeroes, only not to see another
    /// process's data, so pages this pid freed itself stay as they are. malloc
    /// asks for this, and a compile unmaps and remaps its large arrays all along:
    /// their clears through PSRAM were 5% of it.
    pub fn allocate_pages_cleared(self: *ProcessMemoryPool, number_of_pages: i32, pid: c.pid_t, source: AllocSource, may_keep_own: bool) ?[]u8 {
        if (number_of_pages <= 0) {
            return null;
        }
        if (force_swap_once and (source == .heap or source == .heap_slow or source == .heap_fast or source == .heap_top)) {
            force_swap_once = false;
            if (swap_hook) |swap| _ = swap(@as(usize, @intCast(number_of_pages)) * page_size);
        }
        const reserved = self.reserve_pages(number_of_pages, pid, source) orelse
            self.reserve_after_reclaim(number_of_pages, pid, source) orelse return null;

        // Zeroing happens outside `pagepool_lock`, which is the point of the
        // split: the run is already marked used and recorded against this pid,
        // so clearing needs no exclusion, and doing it under a `spin_irq` would
        // mask interrupts for the whole memset -- mmap's measured 407 us,
        // against a ~93 us console budget.
        //
        // Pages are recycled between processes, so they must be cleared before
        // handout. The guarantee reaches direct callers only: through
        // std.mem.Allocator the fresh allocation is overwritten with `undefined`
        // on the way out, so the dynamic loader's image block cannot skip its
        // own zeroing on the strength of this.
        const t_clear = if (perf.enabled) perf.read_cycles() else 0;
        // A board may know a cheaper route to zeroed pages: the rp2350's PSRAM
        // tier is cached write-allocate, so a plain memset moves twice the bytes
        // it needs to and evicts the running process's code doing it.
        if (may_keep_own) {
            self.zero_foreign_pages(reserved.address, pid);
        } else {
            memory.zero_pages(reserved.address);
        }
        // Nobody's until freed: a run can also come back in part, by `shrink`.
        if (self.region_for_addr(@intFromPtr(reserved.address.ptr))) |region| {
            const first = (@intFromPtr(reserved.address.ptr) - region.start_address) / region.page_size;
            set_last_owner(region, first, first + reserved.address.len / region.page_size, 0);
        }
        if (perf.enabled) {
            perf.pool_clear(reserved.tier, perf.read_cycles() -% t_clear, reserved.address.len);
            perf.pool_alloc(reserved.region_pages, reserved.address.len, reserved.tier);
        }
        return reserved.address;
    }

    /// The pool is full: drop cached loader images until the run fits or there
    /// is nothing left to drop. A cache allocation may evict other cache
    /// entries, which is how the cache keeps itself to what is free.
    fn reserve_after_reclaim(self: *ProcessMemoryPool, number_of_pages: i32, pid: c.pid_t, source: AllocSource) ?Reserved {
        const bytes = @as(usize, @intCast(number_of_pages)) * page_size;
        if (reclaim_hook) |hook| {
            while (hook(bytes) != 0) {
                if (self.reserve_pages(number_of_pages, pid, source)) |reserved| return reserved;
            }
        }
        // Not for .heap_fast: fast SRAM is asked for opportunistically (tcc's IR
        // arena) and the caller falls back to the slow tier. Swapping for it
        // wrote make out and back for every compile, for nothing.
        if (source != .heap and source != .heap_slow and source != .heap_top) {
            // An image or a stack that found no room is an exec that fails; say
            // what the pool looked like (not for .heap_fast, which is asked for
            // opportunistically and falls back).
            if (source != .heap_fast and swap_hook != null and bytes >= 64 * 1024) self.report_exhaustion(bytes, pid);
            return null;
        }
        const swap = swap_hook orelse return null;
        while (swap(bytes) != 0) {
            if (self.reserve_pages(number_of_pages, pid, source)) |reserved| return reserved;
        }
        self.report_exhaustion(bytes, pid);
        return null;
    }

    /// One line on why an allocation failed with swap on: free pages and the
    /// longest free run per region, then what each process holds resident and
    /// on swap -- whether the pool was full or only too fragmented.
    fn report_exhaustion(self: *ProcessMemoryPool, bytes: usize, pid: c.pid_t) void {
        const Held = struct { pid: c.pid_t = 0, resident: usize = 0, swapped: usize = 0 };
        var free: [2]usize = .{ 0, 0 };
        var run: [2]usize = .{ 0, 0 };
        var held: [12]Held = @splat(.{});
        var count: usize = 0;
        {
            const flags = pagepool_lock.lock_irqsave();
            defer pagepool_lock.unlock_irqrestore(flags);
            for (self.regions, 0..) |*region, i| {
                if (i >= free.len) break;
                free[i] = (region.page_count - region.used_pages) * region.page_size;
                var at: usize = 0;
                while (at < region.page_count) {
                    if (region.page_bitmap.isSet(at)) {
                        at += 1;
                        continue;
                    }
                    var end = at + 1;
                    while (end < region.page_count and !region.page_bitmap.isSet(end)) end += 1;
                    run[i] = @max(run[i], (end - at) * region.page_size);
                    at = end;
                }
            }
            var it = self.memory_map.iterator();
            while (it.next()) |kv| {
                if (count == held.len) break;
                var h = Held{ .pid = kv.key_ptr.* };
                var node = kv.value_ptr.first;
                while (node) |n| : (node = n.next) {
                    const e: *const ProcessMemoryEntity = @fieldParentPtr("node", n);
                    if (e.swapped()) h.swapped += e.address.len else h.resident += e.address.len;
                }
                held[count] = h;
                count += 1;
            }
        }
        log.err("pool full: pid {d} asked {d} KiB; free {d}+{d} KiB, longest run {d}+{d} KiB", .{
            pid, bytes / 1024, free[0] / 1024, free[1] / 1024, run[0] / 1024, run[1] / 1024,
        });
        for (held[0..count]) |h| log.err("  pid {d}: {d} KiB resident, {d} KiB on swap", .{ h.pid, h.resident / 1024, h.swapped / 1024 });
    }

    /// Find a free run, mark it used and record it against `pid`. Bitmap and
    /// bookkeeping only -- microseconds -- which is what makes `spin_irq` the
    /// right lock for this pool.
    /// A pid as `last_owner` holds it; 0 is nobody, and what does not fit is nobody.
    fn owner_tag(pid: c.pid_t) u8 {
        return if (pid > 0 and pid <= std.math.maxInt(u8)) @intCast(pid) else 0;
    }

    fn set_last_owner(region: *Region, from: usize, to: usize, tag: u8) void {
        if (region.last_owner) |owners| @memset(owners[from..@min(to, owners.len)], tag);
    }

    fn zero_foreign_pages(self: *ProcessMemoryPool, run: []u8, pid: c.pid_t) void {
        const region = self.region_for_addr(@intFromPtr(run.ptr)) orelse {
            memory.zero_pages(run);
            return;
        };
        const owners = region.last_owner orelse {
            memory.zero_pages(run);
            return;
        };
        const tag = owner_tag(pid);
        const first = (@intFromPtr(run.ptr) - region.start_address) / region.page_size;
        const count = run.len / region.page_size;
        var i: usize = 0;
        while (i < count) {
            if (tag != 0 and owners[first + i] == tag) {
                i += 1;
                continue;
            }
            var end = i + 1;
            while (end < count and (tag == 0 or owners[first + end] != tag)) end += 1;
            memory.zero_pages(run[i * region.page_size .. end * region.page_size]);
            i = end;
        }
    }

    /// Exec sets this from the image before loading it. It stays until the next
    /// exec or the process's pages are released, since pids are reused.
    pub fn set_prefers_slow(self: *ProcessMemoryPool, pid: c.pid_t, prefers: bool) void {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const index = std.math.cast(usize, pid) orelse return;
        if (index >= self.slow_pids.len * 32) return;
        const bit = @as(u32, 1) << @intCast(index % 32);
        if (prefers) {
            self.slow_pids[index / 32] |= bit;
        } else {
            self.slow_pids[index / 32] &= ~bit;
        }
    }

    /// Less than half a slow page stays fast: it would free little there, and
    /// rounding it up means clearing a whole slow page at every exec.
    fn goes_slow(self: *const ProcessMemoryPool, pid: c.pid_t, bytes: usize) bool {
        const index = std.math.cast(usize, pid) orelse return false;
        if (index >= self.slow_pids.len * 32 or self.slow_pids[index / 32] & (@as(u32, 1) << @intCast(index % 32)) == 0) return false;
        return bytes * 2 >= self.regions[self.regions.len - 1].page_size;
    }

    fn reserve_pages(self: *ProcessMemoryPool, number_of_pages: i32, pid: c.pid_t, source: AllocSource) ?Reserved {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);

        // Bytes requested: callers count in page_size (the 256 B minimum grain).
        const requested_bytes = @as(usize, @intCast(number_of_pages)) * page_size;
        // Phase stamps (compiled out unless profiling): mmap costs 407 us a
        // call and this is where it goes. See perf.PoolPhase.
        const t_scan = if (perf.enabled) perf.read_cycles() else 0;
        // Twice when a swapped-out process has left pages behind: first for a run
        // that takes none of them, in any tier, and only then for any run at all.
        // A process comes back at the addresses it left, so a page of its given
        // to something that outlives the wait keeps it out for good -- first fit
        // used to hand a waiting shell's low pages to every small allocation of
        // a background job. What still ends up on them is what found no room
        // anywhere else: the big child the swap was made for, which is gone
        // before its parent wakes.
        var pass: usize = if (self.avoid_lent and self.any_lent_pages()) 0 else 1;
        while (pass < 2) : (pass += 1) {
        const avoid_lent = pass == 0;
        // Probe regions fast-first; the first region with a contiguous run wins.
        // The loader cache goes the other way: it should never be what pushes a
        // process out of fast SRAM.
        tiers: for (0..self.regions.len) |probe| {
            const tier = if (source == .cache or source == .heap_slow or source == .heap_top or source == .loader_slow or (source != .heap_fast and self.goes_slow(pid, requested_bytes))) self.regions.len - 1 - probe else probe;
            if (source == .heap_fast and tier != 0) break;
            const region = &self.regions[tier];
            // Round the request up to THIS region's own page grain.
            const region_pages_usize = (requested_bytes + region.page_size - 1) / region.page_size;
            // A region without enough free pages anywhere cannot have them
            // contiguously either, so reject it before walking its bitmap. This
            // is the common case once fast SRAM fills and every subsequent
            // allocation is spilling to PSRAM.
            if (region.used_pages + region_pages_usize > region.page_count) continue;
            // Hold the scan state locally: TCC otherwise reloads these fields on every probe.
            var slot_start = if (source == .heap_top)
                @call(.never_inline, find_free_run_top, .{ region, region_pages_usize }) orelse continue
            else
                @call(.never_inline, find_free_run, .{ region, region_pages_usize, advance_free_hint(region), region.page_count }) orelse continue;
            if (avoid_lent) {
                while (first_lent(region, slot_start, slot_start + region_pages_usize)) |lent_page| {
                    if (source == .heap_top) continue :tiers;
                    slot_start = @call(.never_inline, find_free_run, .{ region, region_pages_usize, lent_page + 1, region.page_count }) orelse continue :tiers;
                }
            }
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
                        if (e.swapped()) continue;
                        const e_start = @intFromPtr(e.address.ptr);
                        const e_end = e_start + e.address.len;
                        if (run_start < e_end and e_start < run_end) {
                            log.err("overlap pid={d} run=0x{x}..0x{x} owner_pid={d} live=0x{x}..0x{x}", .{
                                pid, run_start, run_end, e.pid, e_start, e_end,
                            });
                            break :outer;
                        }
                    }
                }
            }
            const address = @call(.never_inline, record_run, .{ self, region, slot_start, end_index, region_pages_usize, number_of_pages, pid, source, t_mark }) orelse return null;
            return .{
                .address = address,
                .tier = tier,
                .region_pages = region_pages_usize,
            };
        }
        }
        return null;
    }

    fn any_lent_pages(self: *const ProcessMemoryPool) bool {
        for (self.regions) |*region| {
            if (region.lent_pages != 0) return true;
        }
        return false;
    }

    /// Mark a found run used and add it to the pid's list. Out of line for the
    /// stack: the hash map and the kernel heap go deep, and the search's locals are
    /// no use to them. A process's stack holds this.
    fn record_run(self: *ProcessMemoryPool, region: *Region, slot_start: usize, end_index: usize, region_pages_usize: usize, number_of_pages: i32, pid: c.pid_t, source: AllocSource, t_mark: anytype) ?[]u8 {
        mark_used(region, slot_start, end_index);
        if (region.used_pages > region.peak_used) {
            region.peak_used = region.used_pages;
        }
        if (region.used_pages > region.watermark_used) {
            region.watermark_used = region.used_pages;
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
        const entity = slow_heap.allocator_or(self.allocator).create(ProcessMemoryEntity) catch {
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
        if (perf.enabled) perf.pool_record(.book, perf.read_cycles() -% t_book);
        return entity.address;
    }

    pub fn release_pages_for(self: *ProcessMemoryPool, pid: c.pid_t) void {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        if (std.math.cast(usize, pid)) |index| {
            if (index < self.slow_pids.len * 32) self.slow_pids[index / 32] &= ~(@as(u32, 1) << @intCast(index % 32));
        }
        log.debug("release_pages_for: pid={d} pages_before={d}", .{ pid, self.get_used_size() / page_size });
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            var pages_freed: usize = 0;
            var entity_count: usize = 0;
            var next = mapping.value_ptr.first;
            while (next) |entity_node| {
                const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
                // A resident run's copy left on swap goes with it.
                if (entity.kept()) {
                    if (swap_io) |io| io.drop(io.ctx, entity.kept_slot, entity.address.len);
                }
                if (entity.swapped()) {
                    // Its pages are somebody else's by now: only the copy goes --
                    // and whichever of them it had already taken back, waiting
                    // for the rest (a process killed by the swap-in watchdog).
                    if (swap_io) |io| io.drop(io.ctx, entity.swap_slot, entity.address.len);
                    self.release_claims(entity, pid);
                } else if (self.region_for_addr(@intFromPtr(entity.address.ptr))) |region| {
                    const start_index = (@intFromPtr(entity.address.ptr) - region.start_address) / region.page_size;
                    const end_index = start_index + @as(usize, @intCast(entity.address.len)) / region.page_size;
                    const n_pages = end_index - start_index;
                    log.debug("  entity[{d}]: addr=0x{x} pages={d}", .{ entity_count, @intFromPtr(entity.address.ptr), n_pages });
                    mark_free(region, start_index, end_index);
                    // The pid is about to be reused: its next owner is somebody else.
                    set_last_owner(region, start_index, end_index, 0);
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
                    slow_heap.allocator_or(self.allocator).destroy(entity);
                    next_element = list.*.pop();
                }
            }
            _ = self.memory_map.remove(pid);
            log.debug("release_pages_for: pid={d} pages_after={d}", .{ pid, self.get_used_size() / page_size });
        } else {
            log.warn("release_pages_for: pid={d} not found in memory_map", .{pid});
        }
    }

    /// Free `number_of_pages` (256 B grain) at `address`, a page range inside
    /// one of the process's resident mappings that is not that whole mapping:
    /// the mapping is cut at its start or end, or split around the range.
    /// `.refused` leaves everything as it was: the range is in a mapping that
    /// is swapped out, or there was no memory for a second half -- its pages
    /// must not be marked free while the mapping still claims them. `.none`:
    /// no mapping holds the range. `pagepool_lock` held.
    fn free_part_locked(self: *ProcessMemoryPool, list: *ProcessMemoryList, region: *Region, address: *anyopaque, number_of_pages: i32) enum { freed, refused, none } {
        const lo = @intFromPtr(address);
        const region_pages = whole_region_pages(region, number_of_pages);
        const hi = lo + region_pages * region.page_size;
        if ((lo - region.start_address) % region.page_size != 0) return .none;
        var next = list.first;
        while (next) |entity_node| : (next = entity_node.next) {
            const entity: *ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
            const start = @intFromPtr(entity.address.ptr);
            const end = start + entity.address.len;
            if (lo < start or hi > end) continue;
            if (entity.swapped() or (lo == start and hi == end)) return .refused;
            if (lo > start and hi < end) {
                const tail = slow_heap.allocator_or(self.allocator).create(ProcessMemoryEntity) catch return .refused;
                tail.* = .{
                    .address = slicify(@as([*]u8, @ptrFromInt(hi)), end - hi),
                    .pid = entity.pid,
                    .access = entity.access,
                    .source = entity.source,
                    .node = .{},
                };
                list.insertAfter(entity_node, &tail.node);
            }
            drop_kept(entity);
            if (lo == start) {
                entity.address = slicify(@as([*]u8, @ptrFromInt(hi)), end - hi);
            } else {
                entity.address = entity.address[0 .. lo - start];
            }
            const start_index = (lo - region.start_address) / region.page_size;
            mark_free(region, start_index, start_index + region_pages);
            set_last_owner(region, start_index, start_index + region_pages, owner_tag(entity.pid));
            return .freed;
        }
        return .none;
    }

    /// `number_of_pages` of the 256 B grain, in `region`'s pages.
    fn whole_region_pages(region: *const Region, number_of_pages: i32) usize {
        return (@as(usize, @intCast(number_of_pages)) * page_size + region.page_size - 1) / region.page_size;
    }

    pub fn free_pages(self: *ProcessMemoryPool, address: *anyopaque, number_of_pages: i32, pid: c.pid_t) void {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
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
                if (@as(*anyopaque, entity.address.ptr) == address and
                    whole_region_pages(region, number_of_pages) * region.page_size >= entity.address.len)
                {
                    if (entity.swapped()) {
                        // A run still on swap: its pages are somebody else's, or
                        // this process's again only as far as it had claimed them
                        // back. Marking the range free, as below, freed other
                        // processes' pages and left the claimed ones used with no
                        // owner -- which is what kept a killed process's parent
                        // out of its own memory, and its parent, up to the root
                        // shell. Only the copy and the claims go.
                        if (swap_io) |io| io.drop(io.ctx, entity.swap_slot, entity.address.len);
                        self.release_claims(entity, pid);
                        _ = mapping.value_ptr.remove(entity_node);
                        slow_heap.allocator_or(self.allocator).destroy(entity);
                        return;
                    }
                    matched_bytes = entity.address.len;
                    found = true;
                    drop_kept(entity);
                    _ = mapping.value_ptr.remove(entity_node);
                    slow_heap.allocator_or(self.allocator).destroy(entity);
                    break;
                }
                next = entity_node.next;
            }
            // Pages from inside one mapping (libc gives back the whole free
            // pages of its retired pools): the mapping keeps the rest, cut
            // down at either end or split in two.
            if (!found) {
                switch (self.free_part_locked(mapping.value_ptr, region, address, number_of_pages)) {
                    .freed, .refused => return,
                    .none => {},
                }
            }
            const t_mark = if (perf.enabled) perf.read_cycles() else 0;
            perf.pool_record(.free_lookup, t_mark -% t_lookup);
            const start_index = (@intFromPtr(address) - region.start_address) / region.page_size;
            const region_pages = (@as(usize, @intCast(number_of_pages)) * page_size + region.page_size - 1) / region.page_size;
            const end_index = start_index + region_pages;
            mark_free(region, start_index, end_index);
            set_last_owner(region, start_index, end_index, owner_tag(pid));
            if (perf.enabled) {
                perf.pool_record(.free_mark, perf.read_cycles() -% t_mark);
                perf.pool_free();
            }
        }
    }

    /// True if `pid` still owns pool memory.
    ///
    /// A pid handed to a new process must own none. `memory_map` is keyed by pid
    /// alone, so a leftover mapping means two processes share one entry and the
    /// older one's `release_pages_for` marks the younger one's live runs free --
    /// silent corruption that only surfaces once those pages are handed out
    /// again. Checked where a process takes ownership of a pid, so the ordering
    /// bug that produces it (see `reap_terminated`) reports itself instead.
    /// Is this address in the fastest tier?
    pub fn is_fast_address(self: *const ProcessMemoryPool, address: *const anyopaque) bool {
        if (self.regions.len == 0) return false;
        const region = &self.regions[0];
        const a = @intFromPtr(address);
        return a >= region.start_address and a < region.start_address + region.page_count * region.page_size;
    }

    pub fn has_live_mapping(self: *const ProcessMemoryPool, pid: c.pid_t) bool {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const mapping = self.memory_map.getPtr(pid) orelse return false;
        return mapping.first != null;
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
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const mapping = self.memory_map.getPtr(pid) orelse return false;
        var next = mapping.first;
        while (next) |entity_node| {
            const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
            if (@as(*const anyopaque, entity.address.ptr) == address) {
                return entity.address.len >= bytes and !entity.swapped();
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
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        for (self.regions) |*region| region.peak_used = 0;
    }

    /// Sample the observer-controlled high-water mark, in bytes, and clear it.
    /// Read-and-clear, like the XIP counters: a high-water mark only means
    /// something relative to when it was last zeroed.
    ///
    /// The total is a sum of per-tier marks, so it is an upper bound -- two
    /// tiers need not have peaked at the same instant.
    pub fn sample_and_clear_watermark(self: *ProcessMemoryPool) usize {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        var total: usize = 0;
        for (self.regions) |*region| {
            total += region.watermark_used * region.page_size;
            region.watermark_used = region.used_pages;
        }
        return total;
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
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const mapping = self.memory_map.get(pid) orelse return 0;
        var pages: usize = 0;
        var next = mapping.first;
        while (next) |node| {
            const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", node);
            if (!entity.swapped()) pages += entity.address.len / page_size;
            next = node.next;
        }
        return pages;
    }

    // ---- swap ------------------------------------------------------------
    //
    // A process waiting in waitpid touches none of its memory until a child has
    // exited, which is when a build's compiler or linker needs memory most.  So
    // when an allocation finds the pool full, a process waiting like that is
    // written out (kernel/process_manager.zig picks it) and its pages handed to
    // the allocation; it reads them back itself in waitpid before it returns.
    // There is no MMU: they come back at the same addresses, so the swap-in waits
    // until every one of them is free again (normally once the child is reaped).
    // Its stack stays: waitpid is running on it.

    /// Write out every run of `pid` except the one holding `keep` (its stack)
    /// and the loader cache's, and give their pages back.  `pid` must not run
    /// until `swap_in` -- the caller guarantees that.  Returns the bytes freed.
    /// A run at a time, nothing collected on the stack: this runs inside the
    /// allocating process's mmap, on its stack.
    pub fn swap_out(self: *ProcessMemoryPool, pid: c.pid_t, keep: *const anyopaque, io: SwapIo) usize {
        self.ensure_claim_tags();
        var freed: usize = 0;
        while (self.next_to_swap_out(pid, keep)) |entity| {
            // Outside the lock, which masks interrupts: this is SD card I/O.
            // The entity stays put: only `pid` itself changes its list, and it
            // is not running; `release_pages_for` only reaps the dead.
            //
            // Unchanged since it came back? Then the copy it came back from is
            // still right, and nothing is written: a build's make is written
            // out once per compile and changes little in between.
            var reused = false;
            const slot = blk: {
                if (entity.kept()) {
                    if (run_hash(entity.address) == entity.kept_hash) {
                        reused = true;
                        break :blk entity.kept_slot;
                    }
                    io.drop(io.ctx, entity.kept_slot, entity.address.len);
                    entity.kept_slot = no_swap_slot;
                }
                break :blk self.store_run(entity.address, io) catch |err| {
                    log.warn("swap: writing pid {d} out failed: {s}", .{ pid, @errorName(err) });
                    break;
                };
            };
            const flags = pagepool_lock.lock_irqsave();
            defer pagepool_lock.unlock_irqrestore(flags);
            entity.kept_slot = no_swap_slot;
            if (reused) {
                swap_reused_runs += 1;
                swap_reused_bytes += entity.address.len;
            } else {
                swap_written_runs += 1;
                swap_written_bytes += entity.address.len;
            }
            const region = self.region_for_addr(@intFromPtr(entity.address.ptr)) orelse {
                io.drop(io.ctx, slot, entity.address.len);
                break;
            };
            const first = (@intFromPtr(entity.address.ptr) - region.start_address) / region.page_size;
            const last = first + entity.address.len / region.page_size;
            mark_free(region, first, last);
            // Whoever gets these pages next sees zeros, not this process.
            set_last_owner(region, first, last, 0);
            // And they are the last pages anybody is given: it needs them back.
            set_lent(region, first, last, owner_tag(pid), true);
            entity.swap_slot = slot;
            freed += entity.address.len;
        }
        return freed;
    }

    /// `io.store`, making room first if swap is full: kept copies are only a
    /// saving, so they go before a swap-out fails.
    fn store_run(self: *ProcessMemoryPool, data: []const u8, io: SwapIo) !u32 {
        return io.store(io.ctx, data) catch |err| {
            if (!self.drop_all_kept()) return err;
            return io.store(io.ctx, data);
        };
    }

    /// Give back every kept copy; whether there was one.
    fn drop_all_kept(self: *ProcessMemoryPool) bool {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        var any = false;
        var it = self.memory_map.iterator();
        while (it.next()) |kv| {
            var node = kv.value_ptr.first;
            while (node) |n| : (node = n.next) {
                const e: *ProcessMemoryEntity = @fieldParentPtr("node", n);
                if (!e.kept()) continue;
                drop_kept(e);
                any = true;
            }
        }
        return any;
    }

    fn next_to_swap_out(self: *ProcessMemoryPool, pid: c.pid_t, keep: *const anyopaque) ?*ProcessMemoryEntity {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const mapping = self.memory_map.getPtr(pid) orelse return null;
        const k = @intFromPtr(keep);
        var next = mapping.first;
        while (next) |node| : (next = node.next) {
            const entity: *ProcessMemoryEntity = @fieldParentPtr("node", node);
            const start = @intFromPtr(entity.address.ptr);
            if (entity.swapped() or entity.source == .cache) continue;
            if (k >= start and k < start + entity.address.len) continue;
            if (self.region_for_addr(start) == null) continue;
            return entity;
        }
        return null;
    }

    /// Bring back what `swap_out` wrote, at the same addresses.  False, with
    /// nothing changed, while any of those pages belongs to somebody else.
    pub fn swap_in(self: *ProcessMemoryPool, pid: c.pid_t, io: SwapIo) !bool {
        self.ensure_claim_tags();
        if (!self.claim_swapped_pages(pid)) return false;
        // Every page is ours again, so nothing else is handed them while they
        // fill.  A run comes back whole before the next is looked for.
        while (self.next_swapped(pid)) |entity| {
            io.load(io.ctx, entity.swap_slot, entity.address) catch |err| {
                // Its bytes are lost; give the pages back so the process can at
                // least be reaped cleanly.
                self.unclaim_swapped_pages(pid);
                return err;
            };
            // The copy stays for the next swap-out, with what it holds: the
            // hash is taken here, where the bytes are known to match it.
            const hash = run_hash(entity.address);
            const flags = pagepool_lock.lock_irqsave();
            defer pagepool_lock.unlock_irqrestore(flags);
            entity.kept_slot = entity.swap_slot;
            entity.kept_hash = hash;
            entity.swap_slot = no_swap_slot;
        }
        return true;
    }

    pub const SwapBlocker = struct {
        /// The owner of the page: a pid, a loader pseudo-pid (negative), or 0 when the
        /// page is marked used and no run in the map covers it.
        pid: c.pid_t = 0,
        source: []const u8 = "unmapped",
        /// The owner's run.
        address: usize = 0,
        len: usize = 0,
        /// The page of `pid`'s that it sits on, and how many of its pages are taken.
        wanted: usize = 0,
        pages_taken: usize = 0,
    };

    /// Why `swap_in` keeps returning false: the first page of a swapped run of
    /// `pid` that somebody else holds, and who.  A process comes back at the
    /// addresses it left (there is no MMU to put it anywhere else), so one page
    /// handed to a process that outlives the wait keeps it out for good -- and
    /// until this named the holder, all there was to see was a process that had
    /// stopped.
    pub fn swap_in_blocker(self: *ProcessMemoryPool, pid: c.pid_t) ?SwapBlocker {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const mapping = self.memory_map.getPtr(pid) orelse return null;
        var found: ?SwapBlocker = null;
        var next = mapping.first;
        while (next) |node| : (next = node.next) {
            const entity: *ProcessMemoryEntity = @fieldParentPtr("node", node);
            if (!entity.swapped()) continue;
            const region = self.region_for_addr(@intFromPtr(entity.address.ptr)) orelse continue;
            const first = (@intFromPtr(entity.address.ptr) - region.start_address) / region.page_size;
            var page = first;
            while (page < first + entity.address.len / region.page_size) : (page += 1) {
                if (!region.page_bitmap.isSet(page)) continue;
                // Its own, taken back already and held for the rest.
                if (region.claimed_by) |held| {
                    if (held[page] != 0 and held[page] == owner_tag(pid)) continue;
                }
                if (found) |*f| {
                    f.pages_taken += 1;
                    continue;
                }
                const address = region.start_address + page * region.page_size;
                var blocker = SwapBlocker{ .wanted = address, .pages_taken = 1 };
                var it = self.memory_map.iterator();
                owners: while (it.next()) |kv| {
                    var other = kv.value_ptr.first;
                    while (other) |n| : (other = n.next) {
                        const e: *const ProcessMemoryEntity = @fieldParentPtr("node", n);
                        if (e.swapped()) continue;
                        const start = @intFromPtr(e.address.ptr);
                        if (address < start or address >= start + e.address.len) continue;
                        blocker.pid = kv.key_ptr.*;
                        blocker.source = @tagName(e.source);
                        blocker.address = start;
                        blocker.len = e.address.len;
                        break :owners;
                    }
                }
                found = blocker;
            }
        }
        return found;
    }

    /// The per-page claim tags, from the slow heap, before the pool's lock is taken.
    fn ensure_claim_tags(self: *ProcessMemoryPool) void {
        for (self.regions) |*region| {
            if (region.claimed_by != null) continue;
            const a = slow_heap.allocator_or(self.allocator);
            const tags = a.alloc(u8, region.page_count) catch continue;
            const wants = a.alloc(u8, region.page_count) catch {
                a.free(tags);
                continue;
            };
            const lent = a.alloc(u8, region.page_count) catch {
                a.free(tags);
                a.free(wants);
                continue;
            };
            @memset(tags, 0);
            @memset(wants, 0);
            @memset(lent, 0);
            const flags = pagepool_lock.lock_irqsave();
            defer pagepool_lock.unlock_irqrestore(flags);
            if (region.claimed_by == null) {
                region.claimed_by = tags;
                region.wanted_by = wants;
                region.lent_by = lent;
            } else {
                a.free(tags);
                a.free(wants);
                a.free(lent);
            }
        }
    }

    /// Take back the pages of `pid`'s swapped runs; true once it holds them all.
    ///
    /// Page by page: what is free is taken and stays taken across calls, and what
    /// is not is marked wanted, so `mark_free` gives it to this process the
    /// moment its holder lets go. It used to be
    /// all or nothing -- every page free at the same instant, or none marked --
    /// and that starved: a background loop starting one short-lived process
    /// after another (a `sleep`, then a `date`, then the next `sleep`) had each of
    /// them loaded onto the same few just-freed pages, so the pages were never
    /// all free together and a `zig build` on the board stopped for good with
    /// both cores idle. Held pages are tagged with the pid, so a second process
    /// swapped out of the same addresses does not mistake them for its own.
    /// Without tags (no memory for them, or a pid past the tag's range) it is
    /// all or nothing as before.
    fn claim_swapped_pages(self: *ProcessMemoryPool, pid: c.pid_t) bool {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const mapping = self.memory_map.getPtr(pid) orelse return true;
        const tag = owner_tag(pid);
        var missing: usize = 0;
        var next = mapping.first;
        while (next) |node| : (next = node.next) {
            const entity: *ProcessMemoryEntity = @fieldParentPtr("node", node);
            if (!entity.swapped()) continue;
            const region = self.region_for_addr(@intFromPtr(entity.address.ptr)) orelse continue;
            const first = (@intFromPtr(entity.address.ptr) - region.start_address) / region.page_size;
            const claims: ?[]u8 = if (tag != 0) region.claimed_by else null;
            var page = first;
            while (page < first + entity.address.len / region.page_size) : (page += 1) {
                if (claims) |held| {
                    if (held[page] == tag) continue;
                    const wants = region.wanted_by.?;
                    if (wants[page] == 0) wants[page] = tag;
                    if (region.page_bitmap.isSet(page)) {
                        missing += 1;
                        continue;
                    }
                    mark_used(region, page, page + 1);
                    held[page] = tag;
                } else if (region.page_bitmap.isSet(page)) {
                    return false;
                }
            }
        }
        if (missing != 0) return false;
        next = mapping.first;
        while (next) |node| : (next = node.next) {
            const entity: *ProcessMemoryEntity = @fieldParentPtr("node", node);
            if (!entity.swapped()) continue;
            const region = self.region_for_addr(@intFromPtr(entity.address.ptr)) orelse continue;
            const first = (@intFromPtr(entity.address.ptr) - region.start_address) / region.page_size;
            const last = first + entity.address.len / region.page_size;
            if (tag != 0 and region.claimed_by != null) {
                // Held already; from here on they are ordinary pages of the run.
                @memset(region.claimed_by.?[first..last], 0);
                for (region.wanted_by.?[first..last]) |*want| {
                    if (want.* == tag) want.* = 0;
                }
                set_lent(region, first, last, tag, false);
            } else {
                mark_used(region, first, last);
            }
            if (region.used_pages > region.peak_used) region.peak_used = region.used_pages;
            if (region.used_pages > region.watermark_used) region.watermark_used = region.used_pages;
        }
        return true;
    }

    /// Mark or unmark `[from, to)` as lent by `tag`'s process. Unmarking leaves
    /// pages another swapped-out process has since lent from the same addresses.
    fn set_lent(region: *Region, from: usize, to: usize, tag: u8, lent: bool) void {
        const tags = region.lent_by orelse return;
        if (tag == 0) return;
        for (tags[from..to]) |*t| {
            if (lent) {
                if (t.* == 0) region.lent_pages += 1;
                t.* = tag;
            } else if (t.* == tag) {
                t.* = 0;
                region.lent_pages -= 1;
            }
        }
    }

    /// The first page of `[from, to)` a swapped-out process is still owed, if any.
    fn first_lent(region: *const Region, from: usize, to: usize) ?usize {
        const tags = region.lent_by orelse return null;
        if (region.lent_pages == 0) return null;
        for (tags[from..to], from..) |t, page| {
            if (t != 0) return page;
        }
        return null;
    }

    /// Give back what `claim_swapped_pages` took of one swapped run. Caller holds
    /// the pool's lock.
    fn release_claims(self: *ProcessMemoryPool, entity: *const ProcessMemoryEntity, pid: c.pid_t) void {
        const tag = owner_tag(pid);
        if (tag == 0) return;
        const region = self.region_for_addr(@intFromPtr(entity.address.ptr)) orelse return;
        const held = region.claimed_by orelse return;
        const first = (@intFromPtr(entity.address.ptr) - region.start_address) / region.page_size;
        var page = first;
        const wants = region.wanted_by.?;
        set_lent(region, first, first + entity.address.len / region.page_size, tag, false);
        while (page < first + entity.address.len / region.page_size) : (page += 1) {
            if (wants[page] == tag) wants[page] = 0;
            if (held[page] != tag) continue;
            held[page] = 0;
            mark_free(region, page, page + 1);
        }
    }

    /// The load failed after every page was claimed: they are ordinary used pages
    /// by then (the tags are cleared), so all of them go back.
    fn unclaim_swapped_pages(self: *ProcessMemoryPool, pid: c.pid_t) void {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const mapping = self.memory_map.getPtr(pid) orelse return;
        var next = mapping.first;
        while (next) |node| : (next = node.next) {
            const entity: *ProcessMemoryEntity = @fieldParentPtr("node", node);
            if (!entity.swapped()) continue;
            const region = self.region_for_addr(@intFromPtr(entity.address.ptr)) orelse continue;
            const first = (@intFromPtr(entity.address.ptr) - region.start_address) / region.page_size;
            mark_free(region, first, first + entity.address.len / region.page_size);
        }
    }

    fn next_swapped(self: *ProcessMemoryPool, pid: c.pid_t) ?*ProcessMemoryEntity {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const mapping = self.memory_map.getPtr(pid) orelse return null;
        var next = mapping.first;
        while (next) |node| : (next = node.next) {
            const entity: *ProcessMemoryEntity = @fieldParentPtr("node", node);
            if (entity.swapped()) return entity;
        }
        return null;
    }

    /// Bytes out on swap (their pages free) and bytes resident with a copy
    /// still on swap (`kept_slot`) -- /proc/meminfo's SwapUsed and SwapCached.
    pub fn swap_bytes(self: *const ProcessMemoryPool) struct { out: usize, cached: usize } {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        var out: usize = 0;
        var cached: usize = 0;
        var it = self.memory_map.iterator();
        while (it.next()) |kv| {
            var node = kv.value_ptr.first;
            while (node) |n| : (node = n.next) {
                const e: *const ProcessMemoryEntity = @fieldParentPtr("node", n);
                if (e.swapped()) out += e.address.len;
                if (e.kept()) cached += e.address.len;
            }
        }
        return .{ .out = out, .cached = cached };
    }

    /// Whether `pid` has runs out on swap.
    pub fn is_swapped_out(self: *const ProcessMemoryPool, pid: c.pid_t) bool {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        const mapping = self.memory_map.get(pid) orelse return false;
        var next = mapping.first;
        while (next) |node| : (next = node.next) {
            const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", node);
            if (entity.swapped()) return true;
        }
        return false;
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
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
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
                    .heap, .heap_slow, .heap_fast, .heap_top => heap_bytes += bytes,
                    // Only the cache's own pid has these; count them with the
                    // loader's, which is what they are a copy of.
                    .loader, .loader_slow, .cache => loader_bytes += bytes,
                }
                next = node.next;
            }
            if (sram + psram == 0) continue;
            perf.trace("proc pid={d} sram_b={d} psram_b={d} total_b={d} heap_b={d} loader_b={d}", .{ entry.key_ptr.*, sram, psram, sram + psram, heap_bytes, loader_bytes });
        }
    }

    /// One line per live mapping, for `/proc/poolmap`: who holds which memory.
    /// Returns the bytes written; a full buffer truncates the list.
    pub fn write_map(self: *const ProcessMemoryPool, buffer: []u8) usize {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        var written: usize = 0;
        var it = self.memory_map.iterator();
        while (it.next()) |entry| {
            var next = entry.value_ptr.first;
            while (next) |node| {
                const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", node);
                if (buffer.len - written < 48) return written;
                const line = vfmt.print(buffer[written..], "{d} {d} 0x{x} {d} {s}\n", .{
                    entry.key_ptr.*,
                    self.region_index_for_addr(@intFromPtr(entity.address.ptr)) orelse 9,
                    @intFromPtr(entity.address.ptr),
                    entity.address.len,
                    @tagName(entity.source),
                });
                written += line.len;
                next = node.next;
            }
        }
        return written;
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
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
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
        if (region.used_pages > region.watermark_used) {
            region.watermark_used = region.used_pages;
        }

        // Update the entity in the memory map to reflect new size
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            var next = mapping.value_ptr.first;
            while (next) |entity_node| {
                const entity: *ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
                if (@as(*anyopaque, entity.address.ptr) == address) {
                    drop_kept(entity);
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

    /// Shrink an existing allocation in place: the pages past `new_pages` go back
    /// to the pool and the mapping keeps its start address. Returns the shortened
    /// slice, or null when `address` is not the start of a mapping of `old_pages`
    /// owned by `pid` (or `new_pages` is not smaller). Without this a mapping could
    /// only be released whole, so shrinking one meant a copy while both existed.
    pub fn try_shrink_pages(self: *ProcessMemoryPool, address: *anyopaque, old_pages: i32, new_pages: i32, pid: c.pid_t) ?[]u8 {
        const flags = pagepool_lock.lock_irqsave();
        defer pagepool_lock.unlock_irqrestore(flags);
        if (new_pages <= 0 or new_pages >= old_pages) return null;
        const addr_int = @intFromPtr(address);
        const region = self.region_for_addr(addr_int) orelse return null;

        // old/new_pages count in the 256 B grain; round to this region's grain.
        const old_region_pages = (@as(usize, @intCast(old_pages)) * page_size + region.page_size - 1) / region.page_size;
        const new_region_pages = (@as(usize, @intCast(new_pages)) * page_size + region.page_size - 1) / region.page_size;
        const start_index = (addr_int - region.start_address) / region.page_size;

        const mapping = self.memory_map.getPtr(pid) orelse return null;
        var next = mapping.first;
        while (next) |entity_node| : (next = entity_node.next) {
            const entity: *ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
            if (@as(*anyopaque, entity.address.ptr) != address) continue;
            // Only the whole mapping, as the caller knows it, may be cut down:
            // a stale length would free pages this entity does not cover.
            if (entity.address.len != old_region_pages * region.page_size) return null;
            mark_free(region, start_index + new_region_pages, start_index + old_region_pages);
            drop_kept(entity);
            entity.address = entity.address[0 .. new_region_pages * region.page_size];
            return entity.address;
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

test "ProcessMemoryPool.SlowMemoryIsAPerPidPreferenceUntilItsPagesGoBack" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    if (pool.regions.len < 2) return;
    const pages: i32 = @intCast(pool.regions[1].page_size / ProcessMemoryPool.page_size);

    pool.set_prefers_slow(5, true);
    const big = pool.allocate_pages_from(pages, 5, .loader) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!pool.is_fast_address(big.ptr));
    // Under half a slow page stays fast, and so does anybody else.
    const small = pool.allocate_pages_from(1, 5, .loader) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pool.is_fast_address(small.ptr));
    const other = pool.allocate_pages_from(pages, 6, .loader) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pool.is_fast_address(other.ptr));
    // A reused pid starts over.
    pool.release_pages_for(5);
    const again = pool.allocate_pages_from(pages, 5, .loader) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pool.is_fast_address(again.ptr));
    // Thunks go slow whoever asks.
    const thunks = pool.allocate_pages_from(1, 6, .loader_slow) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!pool.is_fast_address(thunks.ptr));
}

test "ProcessMemoryPool.OnlyAProcesssOwnPagesStayUncleared" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    const last = &pool.regions[pool.regions.len - 1];
    if (last.last_owner == null) return;

    const pages: i32 = @intCast(last.page_size / ProcessMemoryPool.page_size);
    const a = pool.allocate_pages_cleared(pages, 1, .heap_slow, true) orelse return error.TestUnexpectedResult;
    @memset(a, 0x5A);
    pool.free_pages(a.ptr, pages, 1);

    // The same process, asking not to clear: its own bytes.
    const b = pool.allocate_pages_cleared(pages, 1, .heap_slow, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(@as(u8, 0x5A), b[0]);
    pool.free_pages(b.ptr, pages, 1);

    // Another process, asking the same: zeroes.
    const c1 = pool.allocate_pages_cleared(pages, 2, .heap_slow, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(a.ptr, c1.ptr);
    try std.testing.expectEqual(@as(u8, 0), c1[0]);
    @memset(c1, 0x5A);
    pool.free_pages(c1.ptr, pages, 2);

    // The same process, not asking: zeroes.
    const d = pool.allocate_pages_cleared(pages, 2, .heap_slow, false) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), d[0]);
    @memset(d, 0x5A);

    // A process's exit: its pid's next owner is somebody else.
    pool.release_pages_for(2);
    const e = pool.allocate_pages_cleared(pages, 2, .heap_slow, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(d.ptr, e.ptr);
    try std.testing.expectEqual(@as(u8, 0), e[0]);
}

test "ProcessMemoryPool.MapFastIsTheFastTierOrNothing" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    if (pool.regions.len < 2) return;

    const fast_pages: i32 = @intCast(pool.regions[0].page_count * pool.regions[0].page_size / ProcessMemoryPool.page_size);
    const all_fast = pool.allocate_pages_from(fast_pages, 1, .heap_fast) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pool.is_fast_address(all_fast.ptr));
    // Full now: the slow tier has room, and the request still fails rather than spill.
    try std.testing.expect(pool.allocate_pages_from(1, 1, .heap_fast) == null);
    // A plain request does spill.
    const spilled = pool.allocate_pages_from(1, 1, .heap) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!pool.is_fast_address(spilled.ptr));
}

test "ProcessMemoryPool.MapTopTakesTheHighestRunOfTheSlowTier" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    const slow_region = &pool.regions[pool.regions.len - 1];
    const region_end = slow_region.start_address + slow_region.page_count * slow_region.page_size;
    const pages_per_run: i32 = @intCast(2 * slow_region.page_size / ProcessMemoryPool.page_size);

    const top = pool.allocate_pages_from(pages_per_run, 1, .heap_top) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(region_end, @intFromPtr(top.ptr) + top.len);
    // The next one goes right below it; a plain request still starts at the bottom.
    const below = pool.allocate_pages_from(pages_per_run, 1, .heap_top) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(top.ptr), @intFromPtr(below.ptr) + below.len);
    const low = pool.allocate_pages_from(pages_per_run, 1, .heap_slow) orelse return error.TestUnexpectedResult;
    try std.testing.expect(@intFromPtr(low.ptr) < @intFromPtr(below.ptr));
    try std.testing.expectEqual(slow_region.start_address, @intFromPtr(low.ptr));

    // A hole at the top is found again, past a used run below it.
    pool.free_pages(top.ptr, pages_per_run, 1);
    const again = pool.allocate_pages_from(pages_per_run, 1, .heap_top) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(top.ptr, again.ptr);
}

test "ProcessMemoryPool.MapSlowPrefersTheSlowTierAndFallsBack" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    if (pool.regions.len < 2) return;

    const slow = pool.allocate_pages_from(1, 1, .heap_slow) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!pool.is_fast_address(slow.ptr));
    // The fast tier was left alone for whoever asks for it.
    const fast = pool.allocate_pages_from(1, 1, .heap) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pool.is_fast_address(fast.ptr));

    const slow_region = &pool.regions[pool.regions.len - 1];
    const rest: i32 = @intCast((slow_region.page_count - slow_region.used_pages) * slow_region.page_size / ProcessMemoryPool.page_size);
    _ = pool.allocate_pages_from(rest, 1, .heap_slow) orelse return error.TestUnexpectedResult;
    const fallback = pool.allocate_pages_from(1, 1, .heap_slow) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pool.is_fast_address(fallback.ptr));
}

test "ProcessMemoryPool.WriteMapListsEveryMapping" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    _ = pool.allocate_pages_from(1, 7, .heap) orelse return error.TestUnexpectedResult;
    _ = pool.allocate_pages_from(1, 9, .loader) orelse return error.TestUnexpectedResult;
    var buffer: [256]u8 = undefined;
    const text = buffer[0..pool.write_map(&buffer)];
    try std.testing.expect(std.mem.indexOf(u8, text, "7 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "9 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " heap\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " loader\n") != null);
    // Too small for a line: truncated, never overrun.
    var small: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), pool.write_map(&small));
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

test "ProcessMemoryPool.ShrinkGivesBackTheTailInPlace" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 4;
    const pages = pool.allocate_pages(8, pid).?;
    const after = pool.allocate_pages(1, pid).?;
    @memset(pages, 0x5a);

    // A stale length is refused and changes nothing.
    try std.testing.expect(pool.try_shrink_pages(pages.ptr, 7, 3, pid) == null);
    // So is growing, shrinking to nothing, or another process's mapping.
    try std.testing.expect(pool.try_shrink_pages(pages.ptr, 8, 8, pid) == null);
    try std.testing.expect(pool.try_shrink_pages(pages.ptr, 8, 0, pid) == null);
    try std.testing.expect(pool.try_shrink_pages(pages.ptr, 8, 3, pid + 1) == null);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 9), pool.get_used_size());

    const shrunk = pool.try_shrink_pages(pages.ptr, 8, 3, pid).?;
    try std.testing.expectEqual(pages.ptr, shrunk.ptr);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 3), shrunk.len);
    for (shrunk) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 4), pool.get_used_size());
    try std.testing.expectEqual(@as(usize, 4), pool.used_pages_for(pid));
    try expect_counts_match_bitmap(&pool);

    // The freed tail sits between the shrunk mapping and `after`: first fit reuses it.
    const reused = pool.allocate_pages(5, pid).?;
    try std.testing.expectEqual(@intFromPtr(pages.ptr) + 3 * ProcessMemoryPool.page_size, @intFromPtr(reused.ptr));

    // The mapping is released by its new length.
    pool.free_pages(shrunk.ptr, 3, pid);
    pool.free_pages(reused.ptr, 5, pid);
    pool.free_pages(after.ptr, 1, pid);
    try expect_counts_match_bitmap(&pool);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.FreeingPagesInsideAMappingCutsOrSplitsIt" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 4;
    const ps = ProcessMemoryPool.page_size;
    const pages = pool.allocate_pages(10, pid).?;
    @memset(pages, 0x5a);

    // The middle: the mapping splits into [0, 3) and [6, 10).
    pool.free_pages(pages.ptr + 3 * ps, 3, pid);
    try std.testing.expectEqual(@as(usize, 7), pool.used_pages_for(pid));
    try expect_counts_match_bitmap(&pool);
    // Its start, by the mapping's own address but fewer pages: cut, not dropped.
    pool.free_pages(pages.ptr, 1, pid);
    try std.testing.expectEqual(@as(usize, 6), pool.used_pages_for(pid));
    // Its end.
    pool.free_pages(pages.ptr + 9 * ps, 1, pid);
    try std.testing.expectEqual(@as(usize, 5), pool.used_pages_for(pid));
    try std.testing.expectEqual(@as(usize, 5 * ps), pool.get_used_size());
    try expect_counts_match_bitmap(&pool);
    for (pages[ps .. 3 * ps]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    for (pages[6 * ps .. 9 * ps]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);

    // The hole goes to whoever asks next.
    const other = pool.allocate_pages(3, pid + 1).?;
    try std.testing.expectEqual(@intFromPtr(pages.ptr) + 3 * ps, @intFromPtr(other.ptr));

    // The pieces are mappings of their own, freed by their own extents.
    pool.free_pages(pages.ptr + ps, 2, pid);
    pool.free_pages(pages.ptr + 6 * ps, 3, pid);
    try std.testing.expectEqual(@as(usize, 0), pool.used_pages_for(pid));
    try std.testing.expectEqual(@as(usize, 3), pool.used_pages_for(pid + 1));
    pool.free_pages(other.ptr, 3, pid + 1);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
    try expect_counts_match_bitmap(&pool);
}

test "ProcessMemoryPool.ARangeInASwappedOutRunIsNotFreed" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 4;
    const ps = ProcessMemoryPool.page_size;
    const pages = pool.allocate_pages(4, pid).?;
    const mapping = pool.memory_map.getPtr(pid).?;
    const entity: *ProcessMemoryPool.ProcessMemoryEntity = @fieldParentPtr("node", mapping.first.?);
    entity.swap_slot = 0; // as swap_out leaves it: the run's pages are its own until swap_in
    pool.free_pages(pages.ptr + ps, 1, pid);
    try std.testing.expectEqual(@as(usize, 4 * ps), entity.address.len);
    try std.testing.expectEqual(@as(usize, 4 * ps), pool.get_used_size());
    entity.swap_slot = std.math.maxInt(u32);
    pool.free_pages(pages.ptr, 4, pid);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
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

test "ProcessMemoryPool.AdvancesHintAcrossWordsAndStopsAtBound" {
    const Pool = ProcessMemoryPool;
    const lengths = [_]usize{ 0, 1, Pool.bits_per_word - 1, Pool.bits_per_word, Pool.bits_per_word + 1, 2 * Pool.bits_per_word + 3 };
    for (lengths) |length| {
        var bitmap = try std.DynamicBitSet.initFull(std.testing.allocator, length);
        defer bitmap.deinit();
        var region: Pool.Region = .{
            .start_address = 0,
            .page_count = length,
            .page_size = Pool.page_size,
            .page_bitmap = bitmap,
        };
        try std.testing.expectEqual(length, Pool.advance_free_hint(&region));
        try std.testing.expectEqual(length, region.first_free_hint);
        try std.testing.expectEqual(length, Pool.advance_free_hint(&region));
        for (0..length) |hole| {
            bitmap.unset(hole);
            region.first_free_hint = 0;
            try std.testing.expectEqual(hole, Pool.advance_free_hint(&region));
            try std.testing.expectEqual(hole, region.first_free_hint);
            try std.testing.expectEqual(hole, Pool.advance_free_hint(&region));
            try std.testing.expectEqual(length - 1, bitmap.count());
            bitmap.set(hole);
        }
    }
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

test "ProcessMemoryPool.MarksPartialWholeAndMultiWordRangesExactly" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 6;
    // Keep every run start off a word boundary, so each length below is marked
    // and freed through two ragged-edged words plus as many whole ones as it
    // spans. A bitmap word is 32 pages on the target and 64 on the host, so
    // the lengths straddle a word edge in either width.
    const divider = pool.allocate_pages(3, pid).?;
    const lengths = [_]i32{ 1, 5, 31, 32, 33, 63, 64, 65, 127 };
    for (lengths) |n| {
        const pages = pool.allocate_pages(n, pid).?;
        try std.testing.expectEqual(@as(usize, @intCast(n)) * ProcessMemoryPool.page_size, pages.len);
        try expect_counts_match_bitmap(&pool);
        try expect_hint_is_lower_bound(&pool);

        pool.free_pages(pages.ptr, n, pid);
        try expect_counts_match_bitmap(&pool);
        try expect_hint_is_lower_bound(&pool);
    }
    try std.testing.expectEqual(@as(usize, 3 * ProcessMemoryPool.page_size), pool.get_used_size());
    _ = divider;
}

test "ProcessMemoryPool.MarkCountsTransitionsNotPages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    // mark_used/mark_free are file-private, and bitmap surgery is only legal
    // under the pool lock; both hold here. The numbers pin the contract the
    // counter depends on: only state *changes* count, so overlapping claims
    // and repeated frees leave used_pages equal to the bitmap's popcount
    // (kernel-page-bitmap-per-page-work.md).
    const flags = pagepool_lock.lock_irqsave();
    defer pagepool_lock.unlock_irqrestore(flags);
    const region = &pool.regions[0];

    ProcessMemoryPool.mark_used(region, 10, 40);
    try std.testing.expectEqual(@as(usize, 30), region.used_pages);
    try expect_counts_match_bitmap(&pool);

    // Overlap: only the 20 fresh pages count.
    ProcessMemoryPool.mark_used(region, 20, 60);
    try std.testing.expectEqual(@as(usize, 50), region.used_pages);
    try expect_counts_match_bitmap(&pool);

    // Idempotent: every page is already claimed.
    ProcessMemoryPool.mark_used(region, 20, 60);
    try std.testing.expectEqual(@as(usize, 50), region.used_pages);

    // Overlapping release: only the 30 set pages come off.
    ProcessMemoryPool.mark_free(region, 30, 70);
    try std.testing.expectEqual(@as(usize, 20), region.used_pages);
    try expect_counts_match_bitmap(&pool);

    // Repeated free of a mostly-free range, running past the region's end:
    // clamped, never a negative counter.
    ProcessMemoryPool.mark_free(region, 0, region.page_count + 4096);
    try std.testing.expectEqual(@as(usize, 0), region.used_pages);
    try expect_counts_match_bitmap(&pool);
    try expect_hint_is_lower_bound(&pool);
}

test "ProcessMemoryPool.RollbackKeepsBitmapAndCounterConsistent" {
    // Fail each allocation in turn: an init failure skips the pool, but a
    // failure after mark_used (memory_map insert, entity create) must roll
    // the bitmap back and leave the counter, the hint and the first-fit
    // placement exactly as they were.
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var pool = ProcessMemoryPool.init(failing.allocator()) catch continue;
        defer pool.deinit();

        const pid: c.pid_t = 9;
        // FailingAllocator keeps failing every allocation once it reaches
        // fail_index, so there is no "retry succeeds": what must hold at the
        // point allocate_pages gives up is the rollback itself.
        const pages = pool.allocate_pages(4, pid) orelse {
            try expect_counts_match_bitmap(&pool);
            try expect_hint_is_lower_bound(&pool);
            try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
            continue;
        };
        try expect_counts_match_bitmap(&pool);
        _ = pages;
    }
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

/// A swap device in a test: slots in memory, counted.
const FakeSwap = struct {
    slots: [16]?[]u8 = @splat(null),
    drops: usize = 0,
    stores: usize = 0,
    fail_store: bool = false,
    /// How many slots it has, at most 16.
    capacity: usize = 16,

    fn io(self: *FakeSwap) ProcessMemoryPool.SwapIo {
        return .{ .ctx = self, .store = store, .load = load, .drop = drop };
    }
    fn store(ctx: *anyopaque, data: []const u8) anyerror!u32 {
        const self: *FakeSwap = @ptrCast(@alignCast(ctx));
        if (self.fail_store) return error.NoSpaceLeft;
        for (self.slots[0..self.capacity], 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = try std.testing.allocator.dupe(u8, data);
                self.stores += 1;
                return @intCast(i);
            }
        }
        return error.NoSpaceLeft;
    }
    fn load(ctx: *anyopaque, slot: u32, data: []u8) anyerror!void {
        const self: *FakeSwap = @ptrCast(@alignCast(ctx));
        @memcpy(data, self.slots[slot].?);
    }
    fn drop(ctx: *anyopaque, slot: u32, bytes: usize) void {
        const self: *FakeSwap = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.slots[slot].?.len == bytes);
        std.testing.allocator.free(self.slots[slot].?);
        self.slots[slot] = null;
        self.drops += 1;
    }
    fn used(self: *const FakeSwap) usize {
        var n: usize = 0;
        for (self.slots) |slot| n += @intFromBool(slot != null);
        return n;
    }
};

test "ProcessMemoryPool.SwapOutKeepsTheStackAndSwapInRestoresAtTheSameAddresses" {
    var swap = FakeSwap{};
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    const pid: c.pid_t = 7;

    const stack = pool.allocate_pages(4, pid).?;
    const data = pool.allocate_pages(8, pid).?;
    const heap = pool.allocate_pages_from(16, pid, .heap).?;
    @memset(stack, 0x5a);
    for (data, 0..) |*b, i| b.* = @truncate(i);
    for (heap, 0..) |*b, i| b.* = @truncate(i * 7);
    const used = pool.get_used_size();

    const freed = pool.swap_out(pid, stack.ptr + 10, swap.io());
    try std.testing.expectEqual(data.len + heap.len, freed);
    try std.testing.expectEqual(used - freed, pool.get_used_size());
    try std.testing.expect(pool.is_swapped_out(pid));
    try std.testing.expectEqual(stack.len / ProcessMemoryPool.page_size, pool.used_pages_for(pid));

    // Somebody else had the pages meanwhile and wrote over them.
    @memset(data, 0xee);
    @memset(heap, 0xee);

    try std.testing.expect(try pool.swap_in(pid, swap.io()));
    try std.testing.expect(!pool.is_swapped_out(pid));
    try std.testing.expectEqual(used, pool.get_used_size());
    for (data, 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(i)), b);
    for (heap, 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(i * 7)), b);
    for (stack) |b| try std.testing.expectEqual(@as(u8, 0x5a), b);
    // The copies stay on swap for the next swap-out.
    try std.testing.expectEqual(@as(usize, 0), swap.drops);
    const bytes = pool.swap_bytes();
    try std.testing.expectEqual(@as(usize, 0), bytes.out);
    try std.testing.expectEqual(data.len + heap.len, bytes.cached);
}

test "ProcessMemoryPool.SwapOutWritesOnlyRunsThatChangedSinceTheyCameBack" {
    var swap = FakeSwap{};
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    const pid: c.pid_t = 7;

    const stack = pool.allocate_pages(4, pid).?;
    const data = pool.allocate_pages(8, pid).?;
    const heap = pool.allocate_pages_from(16, pid, .heap).?;
    @memset(data, 0x11);
    @memset(heap, 0x22);
    _ = pool.swap_out(pid, stack.ptr, swap.io());
    try std.testing.expect(try pool.swap_in(pid, swap.io()));
    try std.testing.expectEqual(@as(usize, 2), swap.stores);
    const written = ProcessMemoryPool.swap_written_runs;
    const reused = ProcessMemoryPool.swap_reused_runs;

    // Only the heap changed while the process ran.
    heap[100] = 0x23;
    try std.testing.expectEqual(data.len + heap.len, pool.swap_out(pid, stack.ptr, swap.io()));
    try std.testing.expectEqual(@as(usize, 3), swap.stores);
    try std.testing.expectEqual(@as(usize, 1), swap.drops); // the heap's stale copy
    try std.testing.expectEqual(written + 1, ProcessMemoryPool.swap_written_runs);
    try std.testing.expectEqual(reused + 1, ProcessMemoryPool.swap_reused_runs);
    try std.testing.expectEqual(data.len + heap.len, pool.swap_bytes().out);

    @memset(data, 0xee);
    @memset(heap, 0xee);
    try std.testing.expect(try pool.swap_in(pid, swap.io()));
    for (data) |b| try std.testing.expectEqual(@as(u8, 0x11), b);
    for (heap, 0..) |b, i| try std.testing.expectEqual(@as(u8, if (i == 100) 0x23 else 0x22), b);
}

test "ProcessMemoryPool.FreeingOrResizingARunGivesItsSwapCopyBack" {
    var swap = FakeSwap{};
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    const pid: c.pid_t = 7;

    const stack = pool.allocate_pages(4, pid).?;
    const a = pool.allocate_pages_from(16, pid, .heap).?;
    const b = pool.allocate_pages_from(16, pid, .heap).?;
    _ = pool.swap_out(pid, stack.ptr, swap.io());
    try std.testing.expect(try pool.swap_in(pid, swap.io()));
    try std.testing.expectEqual(@as(usize, 2), swap.used());

    pool.free_pages(a.ptr, 16, pid);
    try std.testing.expectEqual(@as(usize, 1), swap.used());
    _ = pool.try_shrink_pages(b.ptr, 16, 8, pid).?;
    try std.testing.expectEqual(@as(usize, 0), swap.used());
    try std.testing.expectEqual(@as(usize, 0), pool.swap_bytes().cached);
}

test "ProcessMemoryPool.AFullSwapGivesUpKeptCopiesBeforeASwapOutFails" {
    var swap = FakeSwap{ .capacity = 2 };
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    const first: c.pid_t = 7;
    const second: c.pid_t = 8;

    const stack1 = pool.allocate_pages(4, first).?;
    _ = pool.allocate_pages_from(16, first, .heap).?;
    _ = pool.allocate_pages_from(16, first, .heap).?;
    _ = pool.swap_out(first, stack1.ptr, swap.io());
    try std.testing.expect(try pool.swap_in(first, swap.io()));
    try std.testing.expectEqual(@as(usize, 2), swap.used()); // both kept

    const stack2 = pool.allocate_pages(4, second).?;
    const heap2 = pool.allocate_pages_from(16, second, .heap).?;
    try std.testing.expectEqual(heap2.len, pool.swap_out(second, stack2.ptr, swap.io()));
    try std.testing.expect(pool.is_swapped_out(second));
    try std.testing.expectEqual(@as(usize, 0), pool.swap_bytes().cached);
}

test "ProcessMemoryPool.SwapInWaitsUntilEveryPageIsFreeAgain" {
    var swap = FakeSwap{};
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.avoid_lent = false;
    const parent: c.pid_t = 7;
    const child: c.pid_t = 8;

    const stack = pool.allocate_pages(4, parent).?;
    const heap = pool.allocate_pages_from(16, parent, .heap).?;
    heap[0] = 42;
    _ = pool.swap_out(parent, stack.ptr, swap.io());

    // The child is handed the parent's pages: first fit finds them.
    const taken = pool.allocate_pages_from(16, child, .heap).?;
    try std.testing.expectEqual(heap.ptr, taken.ptr);
    try std.testing.expect(!try pool.swap_in(parent, swap.io()));
    try std.testing.expect(pool.is_swapped_out(parent));

    pool.release_pages_for(child);
    try std.testing.expect(try pool.swap_in(parent, swap.io()));
    try std.testing.expectEqual(@as(u8, 42), heap[0]);
}

test "ProcessMemoryPool.SwapInHoldsThePagesItFindsFreeAgainstAStreamOfShortLivedProcesses" {
    var swap = FakeSwap{};
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.avoid_lent = false;
    const parent: c.pid_t = 7;
    const ps = ProcessMemoryPool.page_size;

    const stack = pool.allocate_pages(4, parent).?;
    const heap = pool.allocate_pages_from(16, parent, .heap).?;
    heap[0] = 42;
    _ = pool.swap_out(parent, stack.ptr, swap.io());

    // A helper is loaded onto the first of the parent's pages: the parent cannot
    // come back yet, but it holds the other fifteen from now on.
    const first = pool.allocate_pages_from(2, 20, .loader).?;
    try std.testing.expectEqual(heap.ptr, first.ptr);
    try std.testing.expect(!try pool.swap_in(parent, swap.io()));
    try std.testing.expectEqual(@as(usize, 2), pool.swap_in_blocker(parent).?.pages_taken);
    try expect_counts_match_bitmap(&pool);

    // The helper exits and the next one starts: it used to land on the same two
    // pages, forever. Now it is somewhere else, and the pages stay free.
    pool.release_pages_for(20);
    const second = pool.allocate_pages_from(2, 21, .loader).?;
    try std.testing.expect(@intFromPtr(second.ptr) >= @intFromPtr(heap.ptr) + 16 * ps or @intFromPtr(second.ptr) + 2 * ps <= @intFromPtr(heap.ptr));
    try std.testing.expect(try pool.swap_in(parent, swap.io()));
    try std.testing.expectEqual(@as(u8, 42), heap[0]);
    try std.testing.expect(pool.swap_in_blocker(parent) == null);
    pool.release_pages_for(21);
    pool.release_pages_for(parent);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
    try expect_counts_match_bitmap(&pool);
}

test "ProcessMemoryPool.ASwappedOutProcessesPagesAreTheLastOnesHandedOut" {
    var swap = FakeSwap{};
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    const parent: c.pid_t = 7;
    const ps = ProcessMemoryPool.page_size;

    const stack = pool.allocate_pages(4, parent).?;
    const heap = pool.allocate_pages_from(16, parent, .heap).?;
    heap[0] = 42;
    _ = pool.swap_out(parent, stack.ptr, swap.io());

    // A background job's small allocation: first fit would put it on the
    // parent's pages. It goes past them.
    const small = pool.allocate_pages_from(2, 20, .heap).?;
    try std.testing.expect(@intFromPtr(small.ptr) >= @intFromPtr(heap.ptr) + 16 * ps or @intFromPtr(small.ptr) + 2 * ps <= @intFromPtr(heap.ptr));
    // So the parent comes straight back, with the job still running.
    try std.testing.expect(try pool.swap_in(parent, swap.io()));
    try std.testing.expectEqual(@as(u8, 42), heap[0]);
    try std.testing.expect(!pool.any_lent_pages());
    pool.release_pages_for(20);
    pool.release_pages_for(parent);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
    try expect_counts_match_bitmap(&pool);
}

test "ProcessMemoryPool.AProcessKilledWhileWaitingForItsPagesGivesBackTheOnesItHeld" {
    var swap = FakeSwap{};
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    pool.avoid_lent = false;
    const parent: c.pid_t = 7;

    const stack = pool.allocate_pages(4, parent).?;
    const heap = pool.allocate_pages_from(16, parent, .heap).?;
    _ = pool.swap_out(parent, stack.ptr, swap.io());
    const holder = pool.allocate_pages_from(2, 20, .heap).?;
    try std.testing.expectEqual(heap.ptr, holder.ptr);
    try std.testing.expect(!try pool.swap_in(parent, swap.io()));

    // The watchdog's kill. Its teardown frees runs one by one before the rest
    // goes at once; neither may free the holder's pages or strand the fourteen
    // the parent had taken back.
    pool.free_pages(heap.ptr, 16, parent);
    try std.testing.expectEqual(holder.len + stack.len, pool.get_used_size());
    try std.testing.expect(pool.owns_mapping(20, holder.ptr, holder.len));
    try expect_counts_match_bitmap(&pool);
    pool.release_pages_for(parent);
    try std.testing.expectEqual(holder.len, pool.get_used_size());
    try expect_counts_match_bitmap(&pool);
    pool.release_pages_for(20);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ReleasingASwappedOutProcessDropsItsCopiesOnly" {
    var swap = FakeSwap{};
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    const pid: c.pid_t = 7;
    const other: c.pid_t = 9;

    const stack = pool.allocate_pages(4, pid).?;
    _ = pool.allocate_pages_from(16, pid, .heap).?;
    _ = pool.swap_out(pid, stack.ptr, swap.io());
    const other_pages = pool.allocate_pages_from(16, other, .heap).?;
    const used = pool.get_used_size();

    pool.release_pages_for(pid);
    try std.testing.expectEqual(@as(usize, 1), swap.drops);
    // The other process keeps the pages the swapped run once had.
    try std.testing.expectEqual(used - stack.len, pool.get_used_size());
    try std.testing.expect(pool.owns_mapping(other, other_pages.ptr, other_pages.len));
}

test "ProcessMemoryPool.SwapOutLeavesTheLoaderCacheAndStopsAtAFailingDevice" {
    var swap = FakeSwap{};
    ProcessMemoryPool.swap_io = swap.io();
    defer ProcessMemoryPool.swap_io = null;
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();
    const pid: c.pid_t = 7;

    const stack = pool.allocate_pages(4, pid).?;
    _ = pool.allocate_pages_from(16, pid, .cache).?;
    try std.testing.expectEqual(@as(usize, 0), pool.swap_out(pid, stack.ptr, swap.io()));

    _ = pool.allocate_pages_from(16, pid, .heap).?;
    swap.fail_store = true;
    try std.testing.expectEqual(@as(usize, 0), pool.swap_out(pid, stack.ptr, swap.io()));
    try std.testing.expect(!pool.is_swapped_out(pid));
}
