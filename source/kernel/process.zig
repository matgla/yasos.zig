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

var pid_counter: c.pid_t = 0;

pub fn ProcessInterface(comptime implementation: anytype) type {
    return struct {
        const Self = @This();

        state: State,
        priority: u8,
        impl: implementation,
        pid: c.pid_t,
        stack: []usize,
        _allocator: std.mem.Allocator,

        pub const State = enum(u2) {
            Ready,
            Blocked,
            Running,
            Killed,
        };

        pub fn create(allocator: std.mem.Allocator, stack_size: u32) !Self {
            const stack = try allocator.alloc(usize, stack_size / @sizeOf(usize));
            if (comptime config.process.use_stack_overflow_detection) {
                stack[0] = 0xdeadbeef;
            }
            pid_counter += 1;
            return Self{
                .state = State.Ready,
                .priority = 0,
                .impl = .{},
                .pid = pid_counter,
                .stack = stack,
                ._allocator = allocator,
            };
        }

        pub fn deinit(self: Self) void {
            self._allocator.free(self.stack);
        }

        pub fn validate_stack(self: Self) bool {
            if (!config.process.use_stack_overflow_detection) @compileError("Stack overflow detection is disabled in config!");
            return self.stack[0] == 0xdeadbeef;
        }
    };
}

const ProcessTester = struct {};

const Process = ProcessInterface(ProcessTester);

test "initialize process" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("Test Failed");
    }
    const stack_size = 1024;
    const process = try Process.create(allocator, stack_size);
    try std.testing.expectEqual(process.pid, 1);
    try std.testing.expectEqual(process.state, Process.State.Ready);
    try std.testing.expectEqual(process.priority, 0);
    try std.testing.expectEqual(process.stack.len * @sizeOf(usize), stack_size);
    defer process.deinit();

    const second_process = try Process.create(allocator, stack_size);
    try std.testing.expectEqual(second_process.pid, 2);
    try std.testing.expectEqual(second_process.state, Process.State.Ready);
    try std.testing.expectEqual(second_process.priority, 0);
    try std.testing.expectEqual(second_process.stack.len * @sizeOf(usize), stack_size);

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
    const process = try Process.create(allocator, stack_size);
    defer process.deinit();
    try std.testing.expect(process.validate_stack());
    process.stack[0] = 0x12345678;
    try std.testing.expect(!process.validate_stack());
}
