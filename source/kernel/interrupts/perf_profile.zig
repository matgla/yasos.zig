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
const config = @import("config");
const c = @import("libc_imports").c;
const hal = @import("hal");

pub const enabled = if (@hasDecl(config.instrumentation, "perf_profiling")) config.instrumentation.perf_profiling else false;

/// Per-allocation tracing (`ldralloc`), off even when profiling is on.
///
/// `trace` writes to the console UART and `Uart.write` busy-waits for TX space,
/// so a trace on a path that runs hundreds of times per spawn does not observe
/// the cost -- it *is* the cost. With this on, the loader's own phase timing
/// attributed ~3 ms of a `cat` load to the allocator when almost all of it was
/// this line's serial output. Turn it on only to attribute allocation *counts*
/// and sizes, never to time anything.
pub const trace_allocations = false;

// Emitted at `.err` so the line reaches the serial console (only err/warn do)
// and, crucially, so the smoke harness filters it out of parsed command output
// via its LOG_PREFIXES list ("[ERR]"/...). The raw per-test serial capture still
// records it, so `grep '\[ERR\]\[tprof\]'` recovers the timings. Using the `# `
// comment convention instead would leak into every command's output parsing
// (sha256sum hash reads, run-output validation) and break unrelated tests.
const tprof_log = std.log.scoped(.tprof);

/// Emit a profiling line (prefixed `[ERR][tprof]`) used to separate dynamic-load
/// time from real execution time. Compiles to a no-op unless perf profiling is
/// enabled, so production builds pay nothing.
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;
    tprof_log.err(fmt, args);
}

const DEMCR: *volatile u32 = @ptrFromInt(0xE000EDFC);
const DWT_CTRL: *volatile u32 = @ptrFromInt(0xE0001000);
const DWT_CYCCNT: *volatile u32 = @ptrFromInt(0xE0001004);
const TRCENA_BIT: u32 = 1 << 24;
const CYCCNTENA_BIT: u32 = 1;

const SYSCALL_COUNT = c.SYSCALL_COUNT;

/// The counters exist only in a profiling build; a production kernel keeps
/// zero-length arrays, so the BSS cost is nothing rather than ~2 KiB.
const SLOTS = if (enabled) SYSCALL_COUNT else 0;

var call_counts: [SLOTS]u32 = @splat(0);
/// SVC entry (stamped in context_switch.S) through the end of the handler.
var total_cycles: [SLOTS]u64 = @splat(0);
/// Handler body only; `total - handler` is the dispatch overhead.
var handler_cycles: [SLOTS]u64 = @splat(0);
var max_cycles: [SLOTS]u32 = @splat(0);
/// Payload bytes moved by read/write, so IO throughput needs no filesystem
/// instrumentation. Saturating: a single window never moves 4 GiB.
var io_bytes: [SLOTS]u32 = @splat(0);
var dropped: u32 = 0;
var cycles_per_us: u32 = 0;
/// Whether DWT_CYCCNT actually counts on this target.
///
/// QEMU's Cortex-M models implement the DWT registers as storage but never
/// advance CYCCNT, so every delta is 0 and the profile prints `us=0` for a
/// syscall that plainly took time. That reads as "syscalls are free" and is the
/// single most expensive way this instrument can be wrong, so entry, and every
/// report derived from it, is tagged with whether the counter was live.
var cycles_available: bool = false;

/// Cycle stamp taken by the SVC handler before it decides fast-path vs
/// trampoline (see `process_syscall_fast_check` in context_switch.S). Reading
/// it here rather than at the top of `_irq_svcall` is what makes the recorded
/// time include exception entry and, for a non-fast syscall, the whole
/// trampoline into thread mode -- the part a compiler-visible timer cannot see.
/// Written unconditionally by the assembler stub when it is compiled in, which
/// build.zig ties to the same Kconfig symbol as `enabled`.
pub export var perf_svc_entry_cycles: u32 = 0;

pub fn init() void {
    if (!enabled) return;
    // Enable DWT cycle counter
    DEMCR.* |= TRCENA_BIT;
    DWT_CYCCNT.* = 0;
    DWT_CTRL.* |= CYCCNTENA_BIT;
    cycles_per_us = @intCast(@max(1, hal.cpu.frequency() / 1_000_000));
    cycles_available = probe_cycle_counter();
    if (!cycles_available) {
        tprof_log.err("DWT_CYCCNT does not advance on this target -- syscall CYCLE" ++
            " counts are unavailable and every *_us figure below reads 0." ++
            " Call counts and byte counts remain valid.", .{});
    }
}

/// True when CYCCNT advances across a short known-nonzero amount of work.
///
/// Two back-to-back reads would be a weaker test: a target that latches the
/// register could return the same value for both and be wrongly failed, so the
/// probe spins a volatile counter between the samples.
fn probe_cycle_counter() bool {
    const before = read_cycles();
    var spin: u32 = 0;
    const spin_ptr: *volatile u32 = &spin;
    while (spin_ptr.* < 64) spin_ptr.* += 1;
    return read_cycles() -% before != 0;
}

/// Whether the numbers this module reports carry cycle information at all.
pub fn has_cycle_counter() bool {
    return enabled and cycles_available;
}

pub inline fn read_cycles() u32 {
    return DWT_CYCCNT.*;
}

/// Deltas above this are not believed. DWT_CYCCNT is 32 bits, so at a few
/// hundred MHz it wraps in single-digit seconds: a syscall that blocked (a tty
/// read, waitpid) comes back with a delta that is modulo-wrapped noise, and one
/// such sample would swamp every real measurement in the same bucket. Counting
/// them separately is honest; folding them in is not.
const implausible_cycles: u32 = 1 << 31;

pub fn record(number: u32, total: u32, handler: u32, bytes: u32) void {
    if (!enabled) return;
    if (number >= SLOTS) return;
    if (total >= implausible_cycles or handler >= implausible_cycles) {
        dropped +|= 1;
        return;
    }
    call_counts[number] +|= 1;
    total_cycles[number] +|= total;
    handler_cycles[number] +|= handler;
    io_bytes[number] +|= bytes;
    if (total > max_cycles[number]) {
        max_cycles[number] = total;
    }
}

pub fn dump(context: *volatile c.perf_dump_context, load_us: u64) void {
    const entries: [*]volatile c.perf_syscall_entry = context.entries;
    const max_entries: usize = @intCast(context.max_entries);
    var written: usize = 0;
    for (0..SLOTS) |i| {
        if (call_counts[i] == 0) continue;
        if (written >= max_entries) break;
        entries[written] = .{
            .syscall_id = @intCast(i),
            .call_count = call_counts[i],
            .total_cycles = total_cycles[i],
            .handler_cycles = handler_cycles[i],
            .max_cycles = max_cycles[i],
            .bytes = io_bytes[i],
        };
        written += 1;
    }
    context.num_entries.* = @intCast(written);
    context.cycles_per_us = cycles_per_us;
    context.dropped = dropped;
    context.load_us = load_us;
}

// ── Page-pool attribution ───────────────────────────────────────────────────
//
// mmap measured at 407 us a call and 52% of tcc's syscall time, which is two
// orders of magnitude more than carving pages out of a bitmap should cost, so
// something inside allocate_pages/free_pages is doing real work. These split
// the two functions into the four (two) things they do, because the fix for
// each is different: a slow scan is an algorithm, a slow clear is a memset
// over a tier the process should not be in, and slow bookkeeping is the kernel
// heap.

pub const PoolPhase = enum(usize) {
    /// Region probe + find_free_run.
    scan,
    /// mark_used over the run.
    mark,
    /// memory_map insert + entity allocation on the kernel heap.
    book,
    /// The mandatory zeroing of recycled pages.
    clear,
    /// free_pages walking the pid's mapping list for the address.
    free_lookup,
    /// mark_free over the run.
    free_mark,
};

const POOL_PHASES = @typeInfo(PoolPhase).@"enum".field_names.len;
const POOL_SLOTS = if (enabled) POOL_PHASES else 0;
/// Two tiers on the boards that have PSRAM; anything beyond falls in the last.
const POOL_TIERS = if (enabled) 2 else 0;

var pool_cycles: [POOL_SLOTS]u64 = @splat(0);
var pool_allocs: u32 = 0;
var pool_frees: u32 = 0;
var pool_pages: u64 = 0;
var pool_cleared_bytes: u64 = 0;
var pool_max_bytes: u32 = 0;
var pool_tier_allocs: [POOL_TIERS]u32 = @splat(0);
/// Requests served from the per-process cache of freed runs (no pool work, no
/// clear) against those that had to go to the pool. The hit rate is what says
/// whether the cache is worth its held memory.
var pool_cache_hits: u32 = 0;
var pool_cache_misses: u32 = 0;
// Clear time and volume split by tier: the same memset costs an order of
// magnitude more against PSRAM than against SRAM, and the two point at
// different fixes -- keep the process out of the slow tier, versus stop
// handing pages back and re-clearing them.
var pool_clear_cycles: [POOL_TIERS]u64 = @splat(0);
var pool_clear_bytes: [POOL_TIERS]u64 = @splat(0);

pub fn pool_record(phase: PoolPhase, cycles: u32) void {
    if (!enabled) return;
    if (cycles >= implausible_cycles) return;
    pool_cycles[@intFromEnum(phase)] +|= cycles;
}

pub fn pool_alloc(pages: usize, bytes: usize, tier: usize) void {
    if (!enabled) return;
    pool_allocs +|= 1;
    pool_pages +|= pages;
    pool_cleared_bytes +|= bytes;
    if (bytes > pool_max_bytes) pool_max_bytes = @intCast(@min(bytes, std.math.maxInt(u32)));
    pool_tier_allocs[@min(tier, POOL_TIERS - 1)] +|= 1;
}

pub fn pool_free() void {
    if (!enabled) return;
    pool_frees +|= 1;
}

pub fn pool_cache_hit() void {
    if (!enabled) return;
    pool_cache_hits +|= 1;
}

pub fn pool_cache_miss() void {
    if (!enabled) return;
    pool_cache_misses +|= 1;
}

pub fn pool_clear(tier: usize, cycles: u32, bytes: usize) void {
    if (!enabled) return;
    pool_record(.clear, cycles);
    if (cycles >= implausible_cycles) return;
    const index = @min(tier, POOL_TIERS - 1);
    pool_clear_cycles[index] +|= cycles;
    pool_clear_bytes[index] +|= bytes;
}

pub const PoolSummary = struct {
    allocs: u32 = 0,
    frees: u32 = 0,
    pages: u64 = 0,
    cleared_bytes: u64 = 0,
    max_bytes: u32 = 0,
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    tier_allocs: [2]u32 = .{ 0, 0 },
    clear_us: [2]u64 = .{ 0, 0 },
    clear_bytes: [2]u64 = .{ 0, 0 },
    /// Indexed by PoolPhase, in microseconds.
    us: [POOL_PHASES]u64 = @splat(0),
};

pub fn pool_summary() PoolSummary {
    var result: PoolSummary = .{};
    if (!enabled) return result;
    const per_us: u64 = @max(1, cycles_per_us);
    result.allocs = pool_allocs;
    result.frees = pool_frees;
    result.pages = pool_pages;
    result.cleared_bytes = pool_cleared_bytes;
    result.max_bytes = pool_max_bytes;
    result.cache_hits = pool_cache_hits;
    result.cache_misses = pool_cache_misses;
    for (0..POOL_TIERS) |i| {
        result.tier_allocs[i] = pool_tier_allocs[i];
        result.clear_us[i] = pool_clear_cycles[i] / per_us;
        result.clear_bytes[i] = pool_clear_bytes[i];
    }
    for (0..POOL_SLOTS) |i| result.us[i] = pool_cycles[i] / per_us;
    return result;
}

// ── open() attribution ──────────────────────────────────────────────────────
//
// open costs 1.9 ms a call and 11 615 of them cost 22 s across tests2+ir_tests,
// which is more than mmap now is. A compile opens ~10 files and tcc's own
// `resolve` phase drives more on top. Split the syscall into the three things
// it does so the fix has an address: the path is either being built, looked up
// through the VFS, or attached to the process's descriptor table.

pub const OpenPhase = enum(usize) {
    /// determine_path_for_file: cwd join + normalisation, on the kernel heap.
    resolve,
    /// The VFS walk that turns a path into a node -- mount lookup plus the
    /// filesystem's own directory search.
    lookup,
    /// attach_file: descriptor allocation and bookkeeping.
    attach,
};

const OPEN_PHASES = @typeInfo(OpenPhase).@"enum".field_names.len;
const OPEN_SLOTS = if (enabled) OPEN_PHASES else 0;

var open_cycles: [OPEN_SLOTS]u64 = @splat(0);
var open_calls: u32 = 0;
var open_misses: u32 = 0;

pub fn open_record(phase: OpenPhase, cycles: u32) void {
    if (!enabled) return;
    if (cycles >= implausible_cycles) return;
    open_cycles[@intFromEnum(phase)] +|= cycles;
}

/// `found` distinguishes an open that produced a file from one that walked the
/// filesystem and came back with nothing -- a failed probe of a candidate path,
/// which is what a library search is made of.
pub fn open_call(found: bool) void {
    if (!enabled) return;
    open_calls +|= 1;
    if (!found) open_misses +|= 1;
}

// Why the *lookup* phase costs what it does.
//
// The phase split above says the VFS walk is ~86% of an open, and no more. A
// warm two-component lookup in the XIP romfs still costs ~126 us, which at
// 532 MHz is ~67 000 cycles to compare a handful of names in memory-mapped
// flash -- so the cost is structural, not IO. These count the two things the
// romfs walk does per directory entry it steps over, which is what turns "the
// walk is slow" into a specific thing to remove:
//
//   headers  FileHeader.init calls, i.e. directory entries visited
//   reads    IFile.read calls made underneath them (each preceded by a seek,
//            both virtual calls through the file interface)
//   allocs   kernel-heap allocations, one per entry for a name that exists
//            only to be compared and freed
//
// Counts rather than cycles on purpose: there are hundreds of reads per open
// and timing each one with a DWT read would cost more than it measured.
var romfs_headers: u32 = 0;
var romfs_reads: u32 = 0;
var romfs_name_allocs: u32 = 0;
/// Cycles spent inside FileHeader.init, so the walk can be separated from the
/// rest of the lookup. Removing 82% of the reads took only 20% off the lookup,
/// which says the walk is not where the remaining time is -- this is what
/// turns that inference into a number.
var romfs_header_cycles: u64 = 0;

pub fn romfs_header(cycles: u32) void {
    if (!enabled) return;
    romfs_headers +|= 1;
    if (cycles < implausible_cycles) romfs_header_cycles +|= cycles;
}

pub fn romfs_read() void {
    if (!enabled) return;
    romfs_reads +|= 1;
}

// Kernel-heap traffic, which is the other candidate for the lookup time the
// romfs walk does not account for: `open` allocates a node per hit, and a miss
// sends the VFS through resolve_symlinks, which builds and normalises a path
// per component. newlib's malloc is a free-list walk, so these are counted and
// timed together.
var kheap_calls: u32 = 0;
var kheap_cycles: u64 = 0;

// The lookup residue. Entry reads and heap traffic together account for well
// under half of a romfs lookup, and the FAT rows carry the same large remainder
// with no romfs walk at all -- so the rest is in the VFS layer itself. These
// bracket its two halves: resolving which mount owns the path, and the
// filesystem's own get() (of which the romfs walk is a measured part).
var vfs_mount_cycles: u64 = 0;
var vfs_fsget_cycles: u64 = 0;

// Inside the filesystem's get(): the path walk versus building the node object
// it returns. fs.get is 102 us of a 114 us romfs lookup while the entry reads
// inside it are only 26 us, so one of these two holds the rest.
var romfs_walk_cycles: u64 = 0;
var romfs_node_cycles: u64 = 0;

// SD block traffic, so `write` and `close` can be split into the filesystem's
// bookkeeping and the card's own time. tcc's writes cost 208 us a call and its
// closes 291 us, on 91-byte average writes -- which is per-operation cost, not
// bandwidth, and these say which side of the block layer it is on.
var disk_writes: u32 = 0;
var disk_write_cycles: u64 = 0;
var disk_write_blocks: u32 = 0;
var disk_reads: u32 = 0;
var disk_read_cycles: u64 = 0;
var disk_read_blocks: u32 = 0;

/// Time spent in wait_for_card_dat0, i.e. blocked on the card rather than
/// moving data. Separates "the card is still programming the last write" from
/// "the write path itself is slow", which is what decides whether deferring
/// the post-write wait can help a given workload at all.
var disk_wait_cycles: u64 = 0;

pub fn disk_wait(cycles: u32) void {
    if (!enabled) return;
    if (cycles < implausible_cycles) disk_wait_cycles +|= cycles;
}

pub fn disk_write(cycles: u32, blocks: u32) void {
    if (!enabled) return;
    disk_writes +|= 1;
    disk_write_blocks +|= blocks;
    if (cycles < implausible_cycles) disk_write_cycles +|= cycles;
}

pub fn disk_read(cycles: u32, blocks: u32) void {
    if (!enabled) return;
    disk_reads +|= 1;
    disk_read_blocks +|= blocks;
    if (cycles < implausible_cycles) disk_read_cycles +|= cycles;
}

pub const DiskSummary = struct {
    writes: u32 = 0,
    write_us: u64 = 0,
    write_blocks: u32 = 0,
    wait_us: u64 = 0,
    reads: u32 = 0,
    read_us: u64 = 0,
    read_blocks: u32 = 0,
};

pub fn disk_summary() DiskSummary {
    var result: DiskSummary = .{};
    if (!enabled) return result;
    const per_us: u64 = @max(1, cycles_per_us);
    result.writes = disk_writes;
    result.write_us = disk_write_cycles / per_us;
    result.write_blocks = disk_write_blocks;
    result.wait_us = disk_wait_cycles / per_us;
    result.reads = disk_reads;
    result.read_us = disk_read_cycles / per_us;
    result.read_blocks = disk_read_blocks;
    return result;
}

pub fn romfs_walk(cycles: u32) void {
    if (!enabled) return;
    if (cycles < implausible_cycles) romfs_walk_cycles +|= cycles;
}

pub fn romfs_node(cycles: u32) void {
    if (!enabled) return;
    if (cycles < implausible_cycles) romfs_node_cycles +|= cycles;
}

pub fn vfs_mount(cycles: u32) void {
    if (!enabled) return;
    if (cycles < implausible_cycles) vfs_mount_cycles +|= cycles;
}

pub fn vfs_fsget(cycles: u32) void {
    if (!enabled) return;
    if (cycles < implausible_cycles) vfs_fsget_cycles +|= cycles;
}

pub fn kernel_heap_op(cycles: u32) void {
    if (!enabled) return;
    kheap_calls +|= 1;
    if (cycles < implausible_cycles) kheap_cycles +|= cycles;
}

pub fn romfs_name_alloc() void {
    if (!enabled) return;
    romfs_name_allocs +|= 1;
}

pub const OpenSummary = struct {
    calls: u32 = 0,
    misses: u32 = 0,
    us: [OPEN_PHASES]u64 = @splat(0),
    headers: u32 = 0,
    reads: u32 = 0,
    name_allocs: u32 = 0,
    header_us: u64 = 0,
    heap_calls: u32 = 0,
    heap_us: u64 = 0,
    mount_us: u64 = 0,
    fsget_us: u64 = 0,
    walk_us: u64 = 0,
    node_us: u64 = 0,
};

pub fn open_summary() OpenSummary {
    var result: OpenSummary = .{};
    if (!enabled) return result;
    const per_us: u64 = @max(1, cycles_per_us);
    result.calls = open_calls;
    result.misses = open_misses;
    result.headers = romfs_headers;
    result.reads = romfs_reads;
    result.name_allocs = romfs_name_allocs;
    result.header_us = romfs_header_cycles / per_us;
    result.heap_calls = kheap_calls;
    result.heap_us = kheap_cycles / per_us;
    result.mount_us = vfs_mount_cycles / per_us;
    result.fsget_us = vfs_fsget_cycles / per_us;
    result.walk_us = romfs_walk_cycles / per_us;
    result.node_us = romfs_node_cycles / per_us;
    for (0..OPEN_SLOTS) |i| result.us[i] = open_cycles[i] / per_us;
    return result;
}

/// Totals for the current window, already converted to microseconds.
///
/// Exists so a process that never calls sys_perf_dump -- ls, cat, vi, a
/// compiled test binary -- still gets its syscall and IO cost reported, from
/// the kernel side at exit. Only tcc was ever instrumented to ask.
pub const TopEntry = struct {
    id: u32 = 0,
    calls: u32 = 0,
    us: u64 = 0,
};

pub const Summary = struct {
    calls: u32 = 0,
    total_us: u64 = 0,
    handler_us: u64 = 0,
    read_bytes: u32 = 0,
    read_us: u64 = 0,
    write_bytes: u32 = 0,
    write_us: u64 = 0,
    dropped: u32 = 0,
    /// The three costliest calls, so a total that looks wrong says which call
    /// made it look wrong instead of needing another run to find out.
    top: [3]TopEntry = .{ .{}, .{}, .{} },
};

pub fn summary() Summary {
    var result: Summary = .{};
    if (!enabled) return result;
    const per_us: u64 = @max(1, cycles_per_us);
    var total: u64 = 0;
    var handler: u64 = 0;
    for (0..SLOTS) |i| {
        result.calls +|= call_counts[i];
        total += total_cycles[i];
        handler += handler_cycles[i];
    }
    result.total_us = total / per_us;
    result.handler_us = handler / per_us;
    if (c.sys_read < SLOTS) {
        result.read_bytes = io_bytes[c.sys_read];
        result.read_us = total_cycles[c.sys_read] / per_us;
    }
    if (c.sys_write < SLOTS) {
        result.write_bytes = io_bytes[c.sys_write];
        result.write_us = total_cycles[c.sys_write] / per_us;
    }
    result.dropped = dropped;

    // Three passes of a max-scan rather than a sort: SLOTS is ~60 and this runs
    // on the exit path of every process.
    var taken: [3]bool = .{ false, false, false };
    var used: [3]usize = .{ 0, 0, 0 };
    for (&result.top, 0..) |*slot, rank| {
        var best: ?usize = null;
        for (0..SLOTS) |i| {
            if (call_counts[i] == 0) continue;
            var already = false;
            for (0..rank) |r| {
                if (taken[r] and used[r] == i) already = true;
            }
            if (already) continue;
            // Cycles first, call count as the tie-break. Without the tie-break a
            // target with no working cycle counter compares 0 > 0 forever and
            // "top" degenerates to the three lowest-numbered syscalls the
            // process happened to use -- which looks like a ranking and is not.
            const better = if (best) |b|
                total_cycles[i] > total_cycles[b] or
                    (total_cycles[i] == total_cycles[b] and call_counts[i] > call_counts[b])
            else
                true;
            if (better) best = i;
        }
        if (best) |i| {
            slot.* = .{ .id = @intCast(i), .calls = call_counts[i], .us = total_cycles[i] / per_us };
            taken[rank] = true;
            used[rank] = i;
        }
    }
    return result;
}

pub fn reset() void {
    if (!enabled) return;
    for (0..POOL_SLOTS) |i| pool_cycles[i] = 0;
    for (0..POOL_TIERS) |i| {
        pool_tier_allocs[i] = 0;
        pool_clear_cycles[i] = 0;
        pool_clear_bytes[i] = 0;
    }
    pool_allocs = 0;
    pool_frees = 0;
    pool_pages = 0;
    pool_cleared_bytes = 0;
    pool_max_bytes = 0;
    pool_cache_hits = 0;
    pool_cache_misses = 0;
    for (0..OPEN_SLOTS) |i| open_cycles[i] = 0;
    open_calls = 0;
    open_misses = 0;
    romfs_headers = 0;
    romfs_reads = 0;
    romfs_name_allocs = 0;
    romfs_header_cycles = 0;
    kheap_calls = 0;
    kheap_cycles = 0;
    vfs_mount_cycles = 0;
    vfs_fsget_cycles = 0;
    romfs_walk_cycles = 0;
    romfs_node_cycles = 0;
    disk_writes = 0;
    disk_write_cycles = 0;
    disk_write_blocks = 0;
    disk_wait_cycles = 0;
    disk_reads = 0;
    disk_read_cycles = 0;
    disk_read_blocks = 0;
    for (0..SLOTS) |i| {
        call_counts[i] = 0;
        total_cycles[i] = 0;
        handler_cycles[i] = 0;
        max_cycles[i] = 0;
        io_bytes[i] = 0;
    }
    dropped = 0;
}
