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

const arch = @import("arch");

var memory_in_use: isize = 0;
var surpressed_memory: isize = 0;
var counter: isize = 0;

pub fn get_usage() usize {
    return if (memory_in_use < 0) 0 else @intCast(memory_in_use);
}

pub fn reset() void {
    memory_in_use = 0;
    surpressed_memory = 0;
    counter = 0;
}

const Tracker = extern struct {
    next: ?*Tracker,
    prev: ?*Tracker,
    surpressed: bool = false,
    data_len: usize,
    data: [*]usize,
    allocated_length: usize,

    pub fn push(self: *Tracker, next: *Tracker) void {
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
        var node: ?*Tracker = self;
        while (node != null) {
            if (node) |n| {
                node = n.next;
                if (n.data_len > 0 and n.data[0] == @intFromPtr(ptr)) {
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
                    return;
                }
            }
        }
        log.err("Invalid free for: 0x{x}", .{@intFromPtr(ptr)});
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

    pub fn print_leaks(self: *Tracker) void {
        var node: ?*Tracker = self;
        while (node != null) {
            if (node) |n| {
                if (n.data_len > 0 and !n.surpressed) {
                    log.err("---------------------------------", .{});
                    log.err("leaked memory allocated at: ", .{});
                    var index: usize = 0;
                    while (index < n.data_len) {
                        log.err("{d}: 0x{x}", .{ index, n.data[index + 1] });
                        index += 1;
                    }
                    log.err("--------------------------------", .{});
                }
                node = n.next;
            }
        }
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
            if (comptime is_leaks_detection_enabled()) {
                const leaked_memory = memory_in_use - surpressed_memory;
                if (leaked_memory > 0) {
                    log.err("Memory leaks detected '{d}' bytes were left", .{leaked_memory});
                }
                tracker.print_leaks();
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

        fn alloc(
            _: *anyopaque,
            len: usize,
            log2_align: std.mem.Alignment,
            return_address: usize,
        ) ?[*]u8 {
            _ = log2_align;
            std.debug.assert(len > 0);
            const ptr = @as([*]u8, @ptrCast(c.malloc(len) orelse return null));
            memory_in_use += @as(isize, @intCast(len));
            counter += 1;
            if (comptime is_leaks_detection_enabled()) {
                log.debug("allocating {d}B at 0x{x}", .{ len, @intFromPtr(ptr) });
                const stack_trace_depth = arch.panic.get_stack_trace_depth(return_address);
                const stack_trace_size = @sizeOf(usize) * (stack_trace_depth);
                log.debug("allocating tracker object with size: {d}", .{@sizeOf(Tracker)});
                const tracker_object = @as(*Tracker, @ptrCast(@alignCast(c.malloc(@sizeOf(Tracker)) orelse return null)));
                tracker_object.next = null;
                tracker_object.prev = null;
                tracker_object.data_len = stack_trace_depth;
                tracker_object.surpressed = false;
                tracker_object.data = @as([*]usize, @ptrCast(@alignCast(c.malloc(@sizeOf(usize) * (stack_trace_size + 1)) orelse return null)));
                tracker_object.data[0] = @intFromPtr(ptr);
                tracker_object.allocated_length = len;
                tracker.push(tracker_object);
                var index: usize = 1;
                var stack = std.debug.StackIterator.init(return_address, @frameAddress());
                while (stack.next()) |ret| {
                    if (@hasField(@TypeOf(options), "verbose") and options.verbose) {
                        log.debug("{d}: 0x{x}", .{ index - 1, ret });
                    }
                    tracker_object.data[index] = ret;
                    index += 1;
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
            _ = log2_buf_align;
            c.free(buf.ptr);
            memory_in_use -= @as(isize, @intCast(buf.len));
            counter -= 1;

            if (comptime is_leaks_detection_enabled()) {
                tracker.remove(buf.ptr, buf.len);
                var index: usize = 1;
                var stack = std.debug.StackIterator.init(return_address, @frameAddress());
                while (stack.next()) |ret| {
                    if (@hasField(@TypeOf(options), "verbose") and options.verbose) {
                        log.debug("{d}: 0x{x}", .{ index - 1, ret });
                    }
                    index += 1;
                }

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
