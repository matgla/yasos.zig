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

var call_counts: [SLOTS]u32 = [_]u32{0} ** SLOTS;
/// SVC entry (stamped in context_switch.S) through the end of the handler.
var total_cycles: [SLOTS]u64 = [_]u64{0} ** SLOTS;
/// Handler body only; `total - handler` is the dispatch overhead.
var handler_cycles: [SLOTS]u64 = [_]u64{0} ** SLOTS;
var max_cycles: [SLOTS]u32 = [_]u32{0} ** SLOTS;
/// Payload bytes moved by read/write, so IO throughput needs no filesystem
/// instrumentation. Saturating: a single window never moves 4 GiB.
var io_bytes: [SLOTS]u32 = [_]u32{0} ** SLOTS;
var dropped: u32 = 0;
var cycles_per_us: u32 = 0;

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

const POOL_PHASES = @typeInfo(PoolPhase).@"enum".fields.len;
const POOL_SLOTS = if (enabled) POOL_PHASES else 0;
/// Two tiers on the boards that have PSRAM; anything beyond falls in the last.
const POOL_TIERS = if (enabled) 2 else 0;

var pool_cycles: [POOL_SLOTS]u64 = [_]u64{0} ** POOL_SLOTS;
var pool_allocs: u32 = 0;
var pool_frees: u32 = 0;
var pool_pages: u64 = 0;
var pool_cleared_bytes: u64 = 0;
var pool_max_bytes: u32 = 0;
var pool_tier_allocs: [POOL_TIERS]u32 = [_]u32{0} ** POOL_TIERS;
/// Requests served from the per-process cache of freed runs (no pool work, no
/// clear) against those that had to go to the pool. The hit rate is what says
/// whether the cache is worth its held memory.
var pool_cache_hits: u32 = 0;
var pool_cache_misses: u32 = 0;
// Clear time and volume split by tier: the same memset costs an order of
// magnitude more against PSRAM than against SRAM, and the two point at
// different fixes -- keep the process out of the slow tier, versus stop
// handing pages back and re-clearing them.
var pool_clear_cycles: [POOL_TIERS]u64 = [_]u64{0} ** POOL_TIERS;
var pool_clear_bytes: [POOL_TIERS]u64 = [_]u64{0} ** POOL_TIERS;

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
    us: [POOL_PHASES]u64 = [_]u64{0} ** POOL_PHASES,
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

const OPEN_PHASES = @typeInfo(OpenPhase).@"enum".fields.len;
const OPEN_SLOTS = if (enabled) OPEN_PHASES else 0;

var open_cycles: [OPEN_SLOTS]u64 = [_]u64{0} ** OPEN_SLOTS;
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

pub const OpenSummary = struct {
    calls: u32 = 0,
    misses: u32 = 0,
    us: [OPEN_PHASES]u64 = [_]u64{0} ** OPEN_PHASES,
};

pub fn open_summary() OpenSummary {
    var result: OpenSummary = .{};
    if (!enabled) return result;
    const per_us: u64 = @max(1, cycles_per_us);
    result.calls = open_calls;
    result.misses = open_misses;
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
            if (best == null or total_cycles[i] > total_cycles[best.?]) best = i;
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
    for (0..SLOTS) |i| {
        call_counts[i] = 0;
        total_cycles[i] = 0;
        handler_cycles[i] = 0;
        max_cycles[i] = 0;
        io_bytes[i] = 0;
    }
    dropped = 0;
}
