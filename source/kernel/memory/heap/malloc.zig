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

pub fn get_usage() usize {
    return if (memory_in_use < 0) 0 else @intCast(memory_in_use);
}

const Tracker = extern struct {
    next: ?*Tracker,
    prev: ?*Tracker,
    surpressed: bool = false,
    data_len: usize,
    data: [*]usize,

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

    pub fn remove(self: *Tracker, ptr: *anyopaque) void {
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
        };

        pub const Self = @This();
        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
            detect_leaks();
        }

        pub fn start_leaks_detection() void {
            if (comptime is_leaks_detection_enabled()) {
                tracker.suppress_all();
                surpressed_memory = memory_in_use;
            }
        }

        pub fn detect_leaks() void {
            if (comptime is_leaks_detection_enabled()) {
                const leaked_memory = memory_in_use - surpressed_memory;
                if (leaked_memory > 0) {
                    log.err("Memory leaks detected '{d}' bytes were left", .{leaked_memory});
                }
                tracker.print_leaks();
            }
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
            if (comptime is_leaks_detection_enabled()) {
                log.debug("allocating {d}B at 0x{x}", .{ len, @intFromPtr(ptr) });
                const stack_trace_depth = arch.panic.get_stack_trace_depth(return_address);
                const stack_trace_size = @sizeOf(usize) * (stack_trace_depth);
                log.debug("allocating tracker object with size: {d}", .{@sizeOf(Tracker)});
                const tracker_object = @as(*Tracker, @alignCast(@ptrCast(c.malloc(@sizeOf(Tracker)) orelse return null)));
                tracker_object.next = null;
                tracker_object.prev = null;
                tracker_object.data_len = stack_trace_depth;
                tracker_object.data = @as([*]usize, @alignCast(@ptrCast(c.malloc(@sizeOf(usize) * (stack_trace_size + 1)) orelse return null)));
                tracker_object.data[0] = @intFromPtr(ptr);
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

            if (comptime is_leaks_detection_enabled()) {
                tracker.remove(buf.ptr);
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
