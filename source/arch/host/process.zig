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

pub const Process = struct {};
pub fn prepare_process_stack(
    stack: []u8,
    comptime exit_handler: *const fn () void,
    entry_point: ?*const anyopaque,
    arg: ?*const anyopaque,
) *u8 {
    _ = exit_handler;
    _ = entry_point;
    _ = arg;
    return @ptrCast(stack.ptr);
}

pub fn initialize_context_switching() void {}
pub fn init() void {}

var thread_counter: i32 = 0;

fn run_process_entry(process_entry: *const fn () void) void {
    process_entry();
}

pub const HostProcess = struct {
    thread: std.Thread,
    pub fn create(allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, exit_handler_impl: anytype) !HostProcess {
        _ = exit_handler_impl;
        const thread = try std.Thread.spawn(
            .{
                .stack_size = stack_size,
                .allocator = allocator,
            },
            run_process_entry,
            .{@as(*const fn () void, @ptrCast(process_entry))},
        );
        thread_counter += 1;
        if (thread_counter == 1) {
            // this is the first process, main tread should be blocked after creation
            while (true) {
                std.Thread.sleep(std.time.ns_per_s * 1);
            }
        }
        return HostProcess{
            .thread = thread,
        };
    }

    pub fn deinit(self: *HostProcess) void {
        _ = self;
    }

    pub fn stack_pointer(self: *const HostProcess) *const u8 {
        _ = self;
        const c: *const u8 = undefined;
        return c;
    }

    pub fn set_stack_pointer(self: *HostProcess, ptr: *u8, blocked_by_process: ?*HostProcess) void {
        _ = self;
        _ = ptr;
        _ = blocked_by_process;
    }

    pub fn vfork(self: *HostProcess, allocator: std.mem.Allocator) !HostProcess {
        _ = allocator;
        return self.*;
    }

    pub fn reinitialize_stack(self: *HostProcess, process_entry: anytype, argc: usize, argv: usize, symbol: usize, got: usize, exit_handler_impl: anytype) void {
        _ = self;
        _ = process_entry;
        _ = argc;
        _ = argv;
        _ = symbol;
        _ = got;
        _ = exit_handler_impl;
    }

    pub fn validate_stack(self: *const HostProcess) bool {
        _ = self;
        return true; // Placeholder for actual stack validation logic
    }

    pub fn restore_stack(self: *HostProcess, blocks_process: ?*HostProcess) void {
        _ = blocks_process;
        _ = self;
    }
};
