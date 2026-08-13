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

const c = @import("c").c;

const log = std.log.scoped(.malloc);
// Dedicated scope so the heap-composition dump is trivially greppable
// (`[ERR][heapprof] ...`) and parsed by scripts/heapdump_report.py.
const heapprof_log = std.log.scoped(.heapprof);

const arch = @import("arch");
// Allocation cost attribution; compiles out unless profiling is enabled.
const perf = @import("../../interrupts/perf_profile.zig");
const config = @import("config");
const kheap_lock = @import("kheap_lock.zig");

pub const KernelAllocatorType = MallocAllocator(.{
    .leak_detection = config.instrumentation.enable_memory_leak_detection,
    .verbose = config.instrumentation.verbose_allocators,
    .dump_stats = config.instrumentation.print_memory_usage,
});

var memory_in_use: isize = 0;
var peak_memory_in_use: isize = 0;
var surpressed_memory: isize = 0;
// One-shot kernel-heap composition dump: when tracked heap first crosses this,
// walk the live allocation trackers and emit a parseable backtrace block to
// serial (`[ERR][heapprof] ...`), symbolized offline by
// scripts/heapdump_report.py. Captures the (boot) peak. Needs leak detection on.
var heapdump_done: bool = false;
const heapdump_threshold_bytes: isize = 50 * 1024;
var counter: isize = 0;

// Size-bucketed net allocation counters for leak diagnosis
pub var bucket_1_4: isize = 0;
pub var bucket_5: isize = 0;
pub var bucket_6: isize = 0;
pub var bucket_7: isize = 0;
pub var bucket_8: isize = 0;
pub var bucket_9_10: isize = 0;
pub var bucket_11_12: isize = 0;
pub var bucket_13_16: isize = 0;
pub var bucket_17_plus: isize = 0;

fn bucket_inc(len: usize) void {
    if (len <= 4) {
        bucket_1_4 += 1;
    } else if (len == 5) {
        bucket_5 += 1;
    } else if (len == 6) {
        bucket_6 += 1;
    } else if (len == 7) {
        bucket_7 += 1;
    } else if (len == 8) {
        bucket_8 += 1;
    } else if (len <= 10) {
        bucket_9_10 += 1;
    } else if (len <= 12) {
        bucket_11_12 += 1;
    } else if (len <= 16) {
        bucket_13_16 += 1;
    } else {
        bucket_17_plus += 1;
    }
}

fn bucket_dec(len: usize) void {
    if (len <= 4) {
        bucket_1_4 -= 1;
    } else if (len == 5) {
        bucket_5 -= 1;
    } else if (len == 6) {
        bucket_6 -= 1;
    } else if (len == 7) {
        bucket_7 -= 1;
    } else if (len == 8) {
        bucket_8 -= 1;
    } else if (len <= 10) {
        bucket_9_10 -= 1;
    } else if (len <= 12) {
        bucket_11_12 -= 1;
    } else if (len <= 16) {
        bucket_13_16 -= 1;
    } else {
        bucket_17_plus -= 1;
    }
}

pub fn get_usage() usize {
    return if (memory_in_use < 0) 0 else @intCast(memory_in_use);
}

/// High-water mark of kernel heap bytes in use since boot (or last reset).
pub fn get_peak_usage() usize {
    return if (peak_memory_in_use < 0) 0 else @intCast(peak_memory_in_use);
}

pub fn get_counter() isize {
    return counter;
}

pub fn reset() void {
    memory_in_use = 0;
    peak_memory_in_use = 0;
    surpressed_memory = 0;
    counter = 0;
}

// ── Kernel free-list integrity check ─────────────────────────────────────────
// newlib-nano holds its free list as `chunk { long size; chunk *next; }` sorted
// by ascending address (that ordering is what _free_r's insertion walk relies
// on). A heap overflow shows up as a garbage `next`, and it is only noticed much
// later — inside _free_r, faulting on `ldr r3,[r3,#4]`, with nothing left to say
// who wrote it. Walking the list at a known point instead attributes the damage
// to the operation that did it.
const NanoChunk = extern struct {
    size: isize,
    next: ?*NanoChunk,
};

extern var __malloc_free_list: ?*NanoChunk;
extern var end: u8;
extern var __heap_limit__: u8;

pub const FreeListFault = struct {
    reason: []const u8,
    node: usize,
    prev: usize,
    index: usize,
};

var free_list_fault_reported: bool = false;

/// Report the first site at which the free list is found broken, then stay
/// quiet, so the log names the operation that did the damage instead of the
/// unrelated _free_r that trips over it some arbitrary number of calls later.
/// `tag` identifies the call site (system_call.zig passes the syscall number).
/// Sprinkle it through a suspect path to bisect down to the offending statement.
pub fn probe(tag: u32) void {
    if (free_list_fault_reported) return;
    const fault = check_free_list() orelse return;
    free_list_fault_reported = true;
    log.err(
        "free list corrupted at tag {d}: {s} node=0x{X:0>8} prev=0x{X:0>8} index={d}",
        .{ tag, fault.reason, fault.node, fault.prev, fault.index },
    );
}

/// Walk the kernel free list and return the first structural violation, or null
/// when it is intact. Allocation-free and log-free so it is safe to call from
/// anywhere, including the syscall path.
pub fn check_free_list() ?FreeListFault {
    const lo = @intFromPtr(&end);
    const hi = @intFromPtr(&__heap_limit__);
    var prev: usize = 0;
    var node = __malloc_free_list;
    var index: usize = 0;
    while (node) |chunk| : (index += 1) {
        const addr = @intFromPtr(chunk);
        const fault = struct {
            fn at(reason: []const u8, a: usize, p: usize, i: usize) FreeListFault {
                return .{ .reason = reason, .node = a, .prev = p, .index = i };
            }
        };
        // A corrupted `next` usually points outside the heap or into the middle
        // of a word; both are cheaper to detect than the resulting fault.
        if (index > 8192) return fault.at("cycle", addr, prev, index);
        if (addr & 3 != 0) return fault.at("misaligned", addr, prev, index);
        if (addr < lo or addr + @sizeOf(NanoChunk) > hi) return fault.at("out-of-heap", addr, prev, index);
        if (chunk.size <= 0 or @as(usize, @intCast(chunk.size)) > hi - addr) return fault.at("bad-size", addr, prev, index);
        // Sortedness is the invariant _free_r walks on, so a break here is
        // exactly what would send it off the rails.
        if (addr <= prev) return fault.at("unsorted", addr, prev, index);
        prev = addr;
        node = chunk.next;
    }
    return null;
}

var get_current_pid_fn: ?*const fn () i32 = null;

pub fn set_get_current_pid(f: *const fn () i32) void {
    get_current_pid_fn = f;
}

fn current_pid() i32 {
    if (get_current_pid_fn) |f| return f();
    return -1;
}

const Tracker = extern struct {
    next: ?*Tracker,
    prev: ?*Tracker,
    surpressed: bool = false,
    data_len: usize,
    data: [*]usize,
    allocated_length: usize,
    owner_pid: i32 = -1,

    var push_count: usize = 0;
    var remove_ok_count: usize = 0;
    var remove_fail_count: usize = 0;

    pub fn push(self: *Tracker, next: *Tracker) void {
        push_count += 1;
        var node: ?*Tracker = self;
        while (node != null) {
            if (node) |n| {
                if (n.next == null) {
                    n.next = next;
                    next.prev = n;
                    break;
                }
                node = n.next;
            }
        }
    }

    pub fn remove(self: *Tracker, ptr: *anyopaque, alloc_len: usize) void {
        var node: ?*Tracker = self.next;
        while (node != null) {
            if (node) |n| {
                node = n.next;
                if (n.data[0] == @intFromPtr(ptr)) {
                    if (n.prev) |p| {
                        p.next = n.next;
                    }
                    if (n.next) |ne| {
                        ne.prev = n.prev;
                    }
                    if (n.allocated_length != alloc_len) {
                        log.err("Mismatched free size for pointer 0x{x}: allocated {d}B, freeing {d}B", .{ @intFromPtr(ptr), n.allocated_length, alloc_len });
                    }
                    c.free(n.data);
                    c.free(n);
                    remove_ok_count += 1;
                    return;
                }
            }
        }
        remove_fail_count += 1;
        log.err("Invalid free for: 0x{x} len={d}", .{ @intFromPtr(ptr), alloc_len });
    }

    pub fn suppress_all(self: *Tracker) void {
        var node: ?*Tracker = self;
        while (node != null) {
            if (node) |n| {
                node = n.next;
                n.surpressed = true;
            }
        }
    }

    pub fn print_leaks(self: *Tracker, is_pid_alive: ?*const fn (i32) bool) void {
        const dead_only = config.instrumentation.leak_report_dead_only;
        var node: ?*Tracker = self.next;
        var printed: usize = 0;
        var leaked_bytes: usize = 0;
        while (node != null) {
            if (node) |n| {
                if (!n.surpressed) {
                    const should_print = if (dead_only)
                        (if (is_pid_alive) |alive_fn| !alive_fn(n.owner_pid) else true)
                    else
                        true;
                    if (should_print) {
                        printed += 1;
                        leaked_bytes += n.allocated_length;
                        log.err("----- pid={d} -----", .{n.owner_pid});
                        log.err("leaked {d}B at 0x{x}", .{ n.allocated_length, n.data[0] });
                        var index: usize = 0;
                        while (index < n.data_len) {
                            log.err("{d}: 0x{x}", .{ index, n.data[index + 1] });
                            index += 1;
                        }
                    }
                }
                node = n.next;
            }
        }
    }

    // Emit a parseable snapshot of every live allocation (size, owner pid, and the
    // top backtrace frames as raw return addresses) for offline symbolization by
    // scripts/heapdump_report.py. The kernel can't symbolize; Python does it
    // against the kernel ELF. Routed through `.err` so the smoke harness filters
    // these lines out of parsed command output while still capturing them in the
    // raw serial log.
    pub fn dump_composition(self: *Tracker) void {
        var node: ?*Tracker = self.next;
        var total: usize = 0;
        var live: usize = 0;
        while (node) |n| {
            total += n.allocated_length;
            live += 1;
            node = n.next;
        }
        heapprof_log.err("begin total={d} live={d}", .{ total, live });
        node = self.next;
        while (node) |n| {
            var bt: [6]usize = @splat(0);
            var i: usize = 0;
            // data[0] is the allocation pointer; data[1..data_len] are the
            // caller-first return addresses captured at alloc time.
            while (i < bt.len and i < n.data_len) : (i += 1) {
                bt[i] = n.data[i + 1];
            }
            heapprof_log.err("a {d} {d} {x} {x} {x} {x} {x} {x}", .{
                n.allocated_length, n.owner_pid, bt[0], bt[1], bt[2], bt[3], bt[4], bt[5],
            });
            node = n.next;
        }
        heapprof_log.err("end", .{});
    }
};

pub fn MallocAllocator(comptime options: anytype) type {
    return struct {
        var tracker: Tracker = .{
            .next = null,
            .prev = null,
            .data_len = 0,
            .data = &.{},
            .allocated_length = 0,
        };

        pub const Self = @This();
        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
            _ = detect_leaks();
        }

        pub fn start_leaks_detection() void {
            if (comptime is_leaks_detection_enabled()) {
                tracker.suppress_all();
                surpressed_memory = memory_in_use;
            }
        }

        pub fn detect_leaks() isize {
            return detect_leaks_filter(null);
        }

        pub fn detect_leaks_filter(is_pid_alive: ?*const fn (i32) bool) isize {
            if (comptime is_leaks_detection_enabled()) {
                const leaked_memory = memory_in_use - surpressed_memory;
                if (leaked_memory > 0) {
                    log.err("Memory leaks detected '{d}' bytes were left", .{leaked_memory});
                }
                tracker.print_leaks(is_pid_alive);
                return leaked_memory;
            }
            return 0;
        }

        fn is_leaks_detection_enabled() bool {
            return if (@hasField(@TypeOf(options), "leak_detection")) options.leak_detection else false;
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        /// What `malloc` on this libc already guarantees. A request for no more
        /// than this is handed straight through.
        const malloc_alignment: usize = 8;

        /// Carve an `alignment`-aligned block out of one `malloc` returned, and
        /// leave the address to hand back to `free` in the word just below it.
        /// `alignment` is larger than `@sizeOf(usize)` on every path here, so
        /// that word stays aligned for a `usize` store.
        fn align_within(base: [*]u8, alignment: usize) [*]u8 {
            const aligned = std.mem.alignForward(usize, @intFromPtr(base) + @sizeOf(usize), alignment);
            const back_reference: *usize = @ptrFromInt(aligned - @sizeOf(usize));
            back_reference.* = @intFromPtr(base);
            return @ptrFromInt(aligned);
        }

        /// Recover what `align_within` was given.
        fn base_of(ptr: [*]u8) [*]u8 {
            const back_reference: *const usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
            return @ptrFromInt(back_reference.*);
        }

        /// How much has to be asked of `malloc` to fit `len` bytes at
        /// `alignment`. A pure function of the two, so `free` can recompute it
        /// without a header of its own.
        fn padded_length(len: usize, alignment: usize) usize {
            return if (alignment > malloc_alignment) len + alignment - 1 + @sizeOf(usize) else len;
        }

        fn alloc(
            _: *anyopaque,
            len: usize,
            log2_align: std.mem.Alignment,
            return_address: usize,
        ) ?[*]u8 {
            std.debug.assert(len > 0);
            // `malloc` aligns to 8 and cannot be asked for more, so anything
            // stricter is carved out of a larger block by hand. Ignoring the
            // request hands back a pointer the caller's `@alignCast` panics on,
            // and only for the allocations that happen to land wrong.
            const alignment = log2_align.toByteUnits();
            // The lock covers the whole body, the `c.malloc` call included: the
            // accounting and leak tracker below are this wrapper's own shared
            // state and are not guarded by `__malloc_lock`. The tracker's
            // walk-then-splice is a long window, and now that syscalls are
            // preemptible two contexts can interleave in it and build a cycle
            // that only faults at shutdown, in `detect_leaks`.
            kheap_lock.yasos_kheap_lock();
            defer kheap_lock.yasos_kheap_unlock();
            const t_alloc = if (perf.enabled) perf.read_cycles() else 0;
            const base = @as([*]u8, @ptrCast(c.malloc(padded_length(len, alignment)) orelse return null));
            const ptr = if (alignment > malloc_alignment) align_within(base, alignment) else base;
            if (perf.enabled) perf.kernel_heap_op(perf.read_cycles() -% t_alloc);
            memory_in_use += @as(isize, @intCast(len));
            if (memory_in_use > peak_memory_in_use) {
                peak_memory_in_use = memory_in_use;
            }
            counter += 1;
            bucket_inc(len);
            if (comptime is_leaks_detection_enabled()) {
                log.debug("allocating {d}B at 0x{x}", .{ len, @intFromPtr(ptr) });
                const max_trace = arch.panic.max_stack_depth;
                log.debug("allocating tracker object with size: {d}", .{@sizeOf(Tracker)});
                const tracker_object = @as(*Tracker, @ptrCast(@alignCast(c.malloc(@sizeOf(Tracker)) orelse return null)));
                tracker_object.next = null;
                tracker_object.prev = null;
                tracker_object.surpressed = false;
                tracker_object.data = @as([*]usize, @ptrCast(@alignCast(c.malloc(@sizeOf(usize) * (max_trace + 2)) orelse return null)));
                tracker_object.data[0] = @intFromPtr(ptr);
                tracker_object.data[1] = return_address; // always capture caller
                tracker_object.allocated_length = len;
                tracker_object.owner_pid = current_pid();
                var index: usize = 2;
                var walker: arch.panic.StackWalker = .init(return_address);
                _ = walker.next(); // skip first (already stored as data[1])
                while (index <= max_trace + 1) {
                    const ret = walker.next() orelse break;
                    if (@hasField(@TypeOf(options), "verbose") and options.verbose) {
                        log.debug("{d}: 0x{x}", .{ index - 1, ret });
                    }
                    tracker_object.data[index] = ret;
                    index += 1;
                }
                tracker_object.data_len = index - 1;
                tracker.push(tracker_object);
                // One-shot heap-composition snapshot at the (boot) peak: the peak
                // is transient and freed before the shell prompt, so dump it the
                // first time we cross the threshold rather than at process exit.
                if (!heapdump_done and memory_in_use > heapdump_threshold_bytes) {
                    heapdump_done = true;
                    tracker.dump_composition();
                }
            }
            if (@hasField(@TypeOf(options), "dump_stats") and options.dump_stats) {
                log.info("usage: {d}B", .{memory_in_use});
            }

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
            _ = return_address;
            // Same reasoning as `alloc`: the free and its bookkeeping have to be
            // one operation, or `tracker.remove` races the splice in `push`.
            kheap_lock.yasos_kheap_lock();
            defer kheap_lock.yasos_kheap_unlock();
            // An over-aligned block is somewhere inside what `malloc` returned;
            // handing this pointer back would be freeing an interior address.
            const alignment = log2_buf_align.toByteUnits();
            c.free(if (alignment > malloc_alignment) base_of(buf.ptr) else buf.ptr);
            memory_in_use -= @as(isize, @intCast(buf.len));
            counter -= 1;
            bucket_dec(buf.len);

            if (comptime is_leaks_detection_enabled()) {
                tracker.remove(buf.ptr, buf.len);

                log.debug("releasing {d}B at 0x{x}, usage: {d}B", .{ buf.len, @intFromPtr(buf.ptr), memory_in_use });
            }
            if (@hasField(@TypeOf(options), "dump_stats") and options.dump_stats) {
                log.info("usage: {d}B", .{memory_in_use});
            }
        }
    };
}

test "MallocAllocator.ShouldAllocateAndFree" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    const ptr = try allocator.alloc(u8, 100);
    defer allocator.free(ptr);

    try std.testing.expectEqual(@as(usize, 100), ptr.len);
}

test "MallocAllocator.ShouldHonourAlignmentBeyondMallocs" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();
    const allocator = malloc_alloc.allocator();

    // 32 is the reservation granule a `Ranked` lock is aligned to; malloc
    // guarantees 8. Enough allocations in a row to catch a fix that only works
    // when the underlying block happens to be aligned already.
    inline for (.{ 16, 32, 64 }) |alignment| {
        var blocks: [8][]align(alignment) u8 = undefined;
        for (&blocks) |*block| {
            block.* = try allocator.alignedAlloc(u8, .fromByteUnits(alignment), 48);
            try std.testing.expectEqual(@as(usize, 0), @intFromPtr(block.ptr) % alignment);
            // Writable over its whole length, i.e. the block really is the size
            // that was asked for and not the padding in front of it.
            @memset(block.*, 0xAB);
        }
        for (blocks) |block| {
            for (block) |byte| try std.testing.expectEqual(@as(u8, 0xAB), byte);
            allocator.free(block);
        }
    }
}

test "MallocAllocator.ShouldHoldAnOverAlignedTypeOnTheHeap" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();
    const allocator = malloc_alloc.allocator();

    // The shape that broke: a heap object carrying an over-aligned member.
    // `create` @alignCasts what the allocator returns, so a wrong answer here
    // is a panic rather than a wrong value.
    const Guarded = struct {
        guard: u32 align(32) = 0,
        payload: u32 = 0,
    };

    var objects: [8]*Guarded = undefined;
    for (&objects) |*object| {
        object.* = try allocator.create(Guarded);
        object.*.* = .{ .payload = 7 };
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(object.*) % 32);
    }
    for (objects) |object| {
        try std.testing.expectEqual(@as(u32, 7), object.payload);
        allocator.destroy(object);
    }
}

test "MallocAllocator.ShouldTrackMemoryUsage" {
    const initial_usage = @import("malloc.zig").get_usage();

    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    const ptr1 = try allocator.alloc(u8, 100);
    const usage_after_alloc1 = @import("malloc.zig").get_usage();
    try std.testing.expect(usage_after_alloc1 >= initial_usage + 100);

    const ptr2 = try allocator.alloc(u8, 200);
    const usage_after_alloc2 = @import("malloc.zig").get_usage();
    try std.testing.expect(usage_after_alloc2 >= usage_after_alloc1 + 200);

    allocator.free(ptr1);
    const usage_after_free1 = @import("malloc.zig").get_usage();
    try std.testing.expect(usage_after_free1 < usage_after_alloc2);

    allocator.free(ptr2);
    const usage_after_free2 = @import("malloc.zig").get_usage();
    try std.testing.expectEqual(initial_usage, usage_after_free2);
}

test "MallocAllocator.ShouldAllocateMultipleTimes" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    var ptrs = try std.ArrayList([]u8).initCapacity(std.testing.allocator, 8);
    defer ptrs.deinit(std.testing.allocator);

    for (0..10) |i| {
        const size = (i + 1) * 10;
        const ptr = try allocator.alloc(u8, size);
        try ptrs.append(std.testing.allocator, ptr);
    }

    for (ptrs.items) |ptr| {
        allocator.free(ptr);
    }
}

test "MallocAllocator.ShouldAllocateDifferentSizes" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    const small = try allocator.alloc(u8, 1);
    defer allocator.free(small);
    try std.testing.expectEqual(@as(usize, 1), small.len);

    const medium = try allocator.alloc(u8, 1024);
    defer allocator.free(medium);
    try std.testing.expectEqual(@as(usize, 1024), medium.len);

    const large = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), large.len);
}

test "MallocAllocator.ShouldAllocateDifferentTypes" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    const bytes = try allocator.alloc(u8, 100);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 100), bytes.len);

    const ints = try allocator.alloc(i32, 50);
    defer allocator.free(ints);
    try std.testing.expectEqual(@as(usize, 50), ints.len);

    const floats = try allocator.alloc(f64, 25);
    defer allocator.free(floats);
    try std.testing.expectEqual(@as(usize, 25), floats.len);
}

test "MallocAllocator.ShouldCreateAndDestroy" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    const TestStruct = struct {
        value: i32,
        name: []const u8,
    };

    const obj = try allocator.create(TestStruct);
    defer allocator.destroy(obj);

    obj.value = 42;
    obj.name = "test";

    try std.testing.expectEqual(@as(i32, 42), obj.value);
    try std.testing.expectEqualStrings("test", obj.name);
}

test "MallocAllocator.ShouldAllocSentinel" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    const str = try allocator.allocSentinel(u8, 10, 0);
    defer allocator.free(str);

    @memcpy(str[0..5], "hello");
    try std.testing.expectEqualStrings("hello", str[0..5]);
    try std.testing.expectEqual(@as(u8, 0), str[10]);
}

test "MallocAllocator.ShouldDupe" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    const original = "Hello, World!";
    const duped = try allocator.dupe(u8, original);
    defer allocator.free(duped);

    try std.testing.expectEqualStrings(original, duped);
    try std.testing.expect(@intFromPtr(original.ptr) != @intFromPtr(duped.ptr));
}

test "MallocAllocator.WithLeakDetection.ShouldDetectLeaks" {
    var malloc_alloc = MallocAllocator(.{ .leak_detection = true }).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    MallocAllocator(.{ .leak_detection = true }).start_leaks_detection();

    // Intentionally leak memory for testing
    _ = try allocator.alloc(u8, 100);
    _ = try allocator.alloc(u8, 128);

    // This should detect the leak when deinit is called
    try std.testing.expectEqual(228, MallocAllocator(.{ .leak_detection = true }).detect_leaks());
}

test "MallocAllocator.WithLeakDetection.ShouldNotDetectLeaksWhenFreed" {
    var malloc_alloc = MallocAllocator(.{ .leak_detection = true }).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    MallocAllocator(.{ .leak_detection = true }).start_leaks_detection();

    const ptr = try allocator.alloc(u8, 100);
    allocator.free(ptr);

    // This should not detect any leaks
    try std.testing.expectEqual(0, MallocAllocator(.{ .leak_detection = true }).detect_leaks());
}

test "MallocAllocator.ShouldHandleZeroUsageCorrectly" {
    const usage = @import("malloc.zig").get_usage();
    try std.testing.expect(usage >= 0);
}

test "MallocAllocator.ShouldAllocateAndFreeInLoop" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    for (0..100) |i| {
        const ptr = try allocator.alloc(u8, (i + 1) * 10);
        // Write some data
        for (ptr, 0..) |*byte, idx| {
            byte.* = @intCast(idx % 256);
        }
        allocator.free(ptr);
    }
}

test "MallocAllocator.ShouldHandleAlignedAllocations" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    const aligned = try allocator.alignedAlloc(u8, .@"16", 100);
    defer allocator.free(aligned);

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 16);
}

test "MallocAllocator.ShouldReallocate" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    var ptr = try allocator.alloc(u8, 100);
    @memset(ptr, 42);

    ptr = try allocator.realloc(ptr, 200);
    defer allocator.free(ptr);

    try std.testing.expectEqual(@as(usize, 200), ptr.len);
    // First 100 bytes should still be 42
    for (ptr[0..100]) |byte| {
        try std.testing.expectEqual(@as(u8, 42), byte);
    }
}

test "MallocAllocator.ShouldShrinkAllocation" {
    var malloc_alloc = MallocAllocator(.{}).init();
    defer malloc_alloc.deinit();

    const allocator = malloc_alloc.allocator();

    var ptr = try allocator.alloc(u8, 1000);
    @memset(ptr, 123);

    ptr = try allocator.realloc(ptr, 100);
    defer allocator.free(ptr);

    try std.testing.expectEqual(@as(usize, 100), ptr.len);
    for (ptr) |byte| {
        try std.testing.expectEqual(@as(u8, 123), byte);
    }
}
