// Copyright (c) 2026 Mateusz Stadnik
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

// Kernel objects that do not need SRAM: pipe rings, filesystem and procfs objects,
// file descriptor tables, loader metadata, the cold half of a process. A region of
// its own at the board's PSRAM (MemoryInfo.Owner.KernelSlow), which the MPU leaves
// unmapped, as the process pool's PSRAM is open to every process.
//
// What may not come from here:
//  - an atomic, a spinlock or a mutex: an exclusive store to PSRAM never succeeds
//    (sync/placement.zig). Reference counters are allocated on their own, so
//    CountersApartAllocator sends requests that small to the kernel heap. An atomic
//    inside a larger object has to stay on the kernel heap with its object.
//  - a DMA target or source the driver does not check for: the XIP cache does not
//    see DMA. The SD driver bounces anything outside SRAM.
//
// Opt-in per allocator, not a tier of the kernel heap: whoever passes this one has
// looked at what it allocates. A board with no such region gets the kernel heap.

const std = @import("std");
const builtin = @import("builtin");

const hal = @import("hal");

const locks = @import("../../sync/locks.zig");
const malloc = @import("malloc.zig");
const CountersApartAllocator = @import("counters_apart_allocator.zig").CountersApartAllocator;
const TmpMemoryPool = @import("tmp_memory_pool.zig").TmpMemoryPool;

/// The arena's allocation unit. Below it a small object wastes more here than the
/// heap's 12-byte chunk header would have cost, but in plentiful memory.
pub const grain = 32;

/// With the arena full, what may still take SRAM. Enough for the kernel to keep
/// working and fail a request later, too little for one file to eat the heap dry,
/// which is a panic.
const spill_to_kernel_heap_limit = 256;

/// RamFs reports no room below this much kernel heap: a node's counter lives there.
const kernel_heap_floor = 4 * 1024;

const Pool = TmpMemoryPool(grain);

pub const SlowHeap = struct {
    pool: Pool,
    kernel_heap: std.mem.Allocator,

    const Self = @This();

    /// `memory` holds the arena's own bitmap too: SRAM is what this is here to save.
    pub fn init(memory: []align(grain) u8, kernel_heap: std.mem.Allocator) !Self {
        const bitmap_bytes = std.mem.alignForward(usize, memory.len / grain / 8 + 2 * @sizeOf(usize), grain);
        var bitmap_memory = std.heap.FixedBufferAllocator.init(memory[0..bitmap_bytes]);
        return .{
            .pool = try Pool.init(bitmap_memory.allocator(), @alignCast(memory[bitmap_bytes..])),
            .kernel_heap = kernel_heap,
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn pages_of(len: usize) i32 {
        return @intCast((len + grain - 1) / grain);
    }

    /// Everything finds its way back by address, so an object can be freed through
    /// this allocator wherever it was allocated.
    fn owns(self: *const Self, address: usize) bool {
        return address >= self.pool.start_address and address < self.pool.start_address + self.pool.memory_size;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        if (alignment.toByteUnits() > grain) {
            return self.kernel_heap.rawAlloc(len, alignment, return_address);
        }
        const memory = reserve: {
            const flags = lock.lock_irqsave();
            defer lock.unlock_irqrestore(flags);
            break :reserve self.pool.reserve_pages(pages_of(len));
        };
        if (memory) |pages| return pages.ptr;
        if (len > spill_to_kernel_heap_limit) return null;
        spilled_to_kernel_heap +%= 1;
        return self.kernel_heap.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!self.owns(@intFromPtr(memory.ptr))) {
            return self.kernel_heap.rawResize(memory, alignment, new_len, return_address);
        }
        const old_pages = pages_of(memory.len);
        const new_pages = pages_of(new_len);
        if (old_pages == new_pages) return true;
        const flags = lock.lock_irqsave();
        defer lock.unlock_irqrestore(flags);
        if (new_pages < old_pages) return self.pool.shrink_pages(memory.ptr, old_pages, new_pages) != null;
        return self.pool.try_extend_pages(memory.ptr, old_pages, new_pages) != null;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!self.owns(@intFromPtr(memory.ptr))) {
            return self.kernel_heap.rawRemap(memory, alignment, new_len, return_address);
        }
        return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!self.owns(@intFromPtr(memory.ptr))) {
            self.kernel_heap.rawFree(memory, alignment, return_address);
            return;
        }
        const flags = lock.lock_irqsave();
        defer lock.unlock_irqrestore(flags);
        self.pool.free_pages(memory.ptr, pages_of(memory.len));
    }
};

var lock: locks.Ranked(.kslow) = .{};
var heap: ?SlowHeap = null;
var apart: CountersApartAllocator = undefined;
/// Requests the full arena sent to SRAM. Not zero means the arena is too small.
pub var spilled_to_kernel_heap: u32 = 0;

/// Call once the board knows its memory, before anything is handed the result.
/// Returns what to allocate slow objects from, which is `kernel_heap` itself on a
/// board without the region.
pub fn install(kernel_heap: std.mem.Allocator) std.mem.Allocator {
    for (hal.memory.get_memory_layout()) |region| {
        if (region.owner != .KernelSlow or region.size == 0) continue;
        const start = std.mem.alignForward(usize, region.start_address, grain);
        const end = std.mem.alignBackward(usize, region.start_address + region.size, grain);
        if (end <= start) break;
        const memory: [*]align(grain) u8 = @ptrFromInt(start);
        heap = SlowHeap.init(memory[0 .. end - start], kernel_heap) catch break;
        apart = .{ .arena = heap.?.allocator(), .counters = kernel_heap };
        return apart.allocator();
    }
    return kernel_heap;
}

/// The slow heap, or `fallback` when there is none (host tests, no PSRAM).
pub fn allocator_or(fallback: std.mem.Allocator) std.mem.Allocator {
    return if (heap != null) apart.allocator() else fallback;
}

/// The kernel heap, for what the slow allocator was passed down to but runs on every
/// read: a filesystem's cache lines, a path buffer that lives for one system call.
pub fn fast_or(fallback: std.mem.Allocator) std.mem.Allocator {
    return if (heap) |*h| h.kernel_heap else fallback;
}

pub fn used_bytes() usize {
    return if (heap) |*h| h.pool.get_used_size() else 0;
}

pub fn peak_bytes() usize {
    return if (heap) |*h| h.pool.get_peak_size() else 0;
}

/// What a RamFs on this allocator may still count on. Its bytes land in the arena,
/// but each node's counter takes kernel heap, so a few thousand empty files could
/// still run that dry: nothing is left below the floor.
pub fn headroom() usize {
    const h = if (heap) |*found| found else return malloc.headroom();
    if (malloc.headroom() < kernel_heap_floor) return 0;
    return h.pool.memory_size - h.pool.get_used_size();
}

const testing = std.testing;

const TestHeap = struct {
    memory: [4096]u8 align(grain) = undefined,
    heap: SlowHeap = undefined,

    fn start(self: *TestHeap) !void {
        self.heap = try SlowHeap.init(&self.memory, testing.allocator);
    }

    fn in_arena(self: *TestHeap, pointer: anytype) bool {
        return self.heap.owns(@intFromPtr(pointer));
    }
};

test "SlowHeap.AllocationsComeFromTheArenaAndGoBack" {
    var sut = TestHeap{};
    try sut.start();
    const allocator = sut.heap.allocator();

    const first = try allocator.alloc(u8, 100);
    try testing.expect(sut.in_arena(first.ptr));
    const used = sut.heap.pool.get_used_size();
    try testing.expectEqual(@as(usize, 128), used);

    allocator.free(first);
    try testing.expectEqual(@as(usize, 0), sut.heap.pool.get_used_size());
}

test "SlowHeap.TheBitmapIsInsideTheArena" {
    var sut = TestHeap{};
    try sut.start();
    const address = @intFromPtr(sut.heap.pool.page_bitmap.unmanaged.masks);
    try testing.expect(address >= @intFromPtr(&sut.memory));
    try testing.expect(address < sut.heap.pool.start_address);
    try testing.expect(sut.heap.pool.page_count > 0);
}

test "SlowHeap.AlignmentPastAGrainGoesToTheKernelHeap" {
    var sut = TestHeap{};
    try sut.start();
    const allocator = sut.heap.allocator();
    const aligned = try allocator.alignedAlloc(u8, .@"64", 16);
    defer allocator.free(aligned);
    try testing.expect(!sut.in_arena(aligned.ptr));
}

test "SlowHeap.AFullArenaSpillsSmallRequestsAndRefusesLargeOnes" {
    var sut = TestHeap{};
    try sut.start();
    const allocator = sut.heap.allocator();
    const everything = try allocator.alloc(u8, sut.heap.pool.page_count * grain);
    defer allocator.free(everything);

    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, spill_to_kernel_heap_limit + 1));

    // Freed through the same allocator, found by its address.
    const spilled = try allocator.alloc(u8, spill_to_kernel_heap_limit);
    try testing.expect(!sut.in_arena(spilled.ptr));
    allocator.free(spilled);
}

test "SlowHeap.ResizeWithinAGrainNeedsNoRoomAndGrowthStaysInPlaceOrFails" {
    var sut = TestHeap{};
    try sut.start();
    const allocator = sut.heap.allocator();
    var block = try allocator.alloc(u8, 8);
    try testing.expect(allocator.resize(block, grain));
    block = block.ptr[0..grain];
    const next = try allocator.alloc(u8, 8);
    defer allocator.free(next);
    try testing.expect(!allocator.resize(block, grain + 1));
    allocator.free(block);
}

test "SlowHeap.ANonArenaBlockResizesAndFreesThroughTheKernelHeap" {
    var sut = TestHeap{};
    try sut.start();
    const allocator = sut.heap.allocator();
    const foreign = try testing.allocator.alloc(u8, 16);
    try testing.expect(!sut.in_arena(foreign.ptr));
    allocator.free(foreign);
}

test "SlowHeap.WithoutARegionTheFallbackIsWhatYouGet" {
    try testing.expectEqual(@as(usize, 0), used_bytes());
    try testing.expectEqual(testing.allocator.ptr, allocator_or(testing.allocator).ptr);
}
