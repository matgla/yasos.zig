//
// process.zig
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

const c = @cImport({
    @cInclude("sys/types.h");
});

const config = @import("config");
const arch_process = @import("../arch/arch.zig").process;

var pid_counter: u32 = 0;

fn exit_handler() void {
    while (true) {}
}

pub fn init() void {
    arch_process.init();
}

pub fn ProcessInterface(comptime implementation: anytype) type {
    return struct {
        const Self = @This();
        const stack_marker: u32 = 0xdeadbeef;

        state: State,
        priority: u8,
        impl: implementation,
        pid: u32,
        stack: []align(8) u8,
        stack_position: *const u8,
        _allocator: std.mem.Allocator,

        pub const State = enum(u2) {
            Ready,
            Blocked,
            Running,
            Killed,
        };

        pub fn create(allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, _: anytype) !Self {
            const stack: []align(8) u8 = try allocator.alignedAlloc(u8, 8, stack_size);
            if (comptime config.process.use_stack_overflow_detection) {
                @memcpy(stack[0..@sizeOf(u32)], std.mem.asBytes(&stack_marker));
            }
            pid_counter += 1;
            const stack_position = implementation.prepare_process_stack(stack, &exit_handler, process_entry);
            return Self{
                .state = State.Ready,
                .priority = 0,
                .impl = .{},
                .pid = pid_counter,
                .stack = stack,
                .stack_position = stack_position,
                ._allocator = allocator,
            };
        }

        pub fn deinit(self: Self) void {
            self._allocator.free(self.stack);
        }

        pub fn validate_stack(self: Self) bool {
            if (!config.process.use_stack_overflow_detection) @compileError("Stack overflow detection is disabled in config!");
            return std.mem.eql(u8, self.stack[0..@sizeOf(u32)], std.mem.asBytes(&stack_marker));
        }

        pub fn stack_pointer(self: Self) *const u8 {
            if (config.process.use_stack_overflow_detection) {
                if (!self.validate_stack()) {
                    if (!config.process.use_mpu_stack_protection) {
                        @panic("Stack overlflow occured, please reset");
                    } else {
                        @panic("TODO: implement process kill here");
                    }
                }
            }
            return self.stack_position;
        }

        pub fn set_stack_pointer(self: *Self, ptr: *const u8) void {
            self.stack_position = ptr;
        }

        pub fn stack_usage(self: Self) usize {
            return self.stack.len - (@intFromPtr(&self.stack[self.stack.len]) - @intFromPtr(self.stack_position));
        }
    };
}

pub fn initialize_context_switching() void {
    arch_process.initialize_context_switching();
}

pub const Process = ProcessInterface(arch_process);

fn process_init() void {}

test "initialize process" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("Test Failed");
    }
    const stack_size = 1024;
    const process = try Process.create(allocator, stack_size, process_init);
    try std.testing.expectEqual(process.pid, 1);
    try std.testing.expectEqual(process.state, Process.State.Ready);
    try std.testing.expectEqual(process.priority, 0);
    try std.testing.expectEqual(process.stack.len, stack_size);
    defer process.deinit();

    const second_process = try Process.create(allocator, stack_size, process_init);
    try std.testing.expectEqual(second_process.pid, 2);
    try std.testing.expectEqual(second_process.state, Process.State.Ready);
    try std.testing.expectEqual(second_process.priority, 0);
    try std.testing.expectEqual(second_process.stack.len, stack_size);

    defer second_process.deinit();
}

test "detect stack overflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("Test Failed");
    }
    const stack_size = 1024;
    const process = try Process.create(allocator, stack_size, process_init);
    defer process.deinit();
    try std.testing.expect(process.validate_stack());
    process.stack[0] = 0x12;
    try std.testing.expect(!process.validate_stack());
}
