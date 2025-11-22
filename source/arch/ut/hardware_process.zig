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

pub const HardwareProcess = struct {
    var stack_dat: usize = 0;
    _sp: ?*const u8,
    stack: []u8,
    stack_position: *u8,

    pub fn create(allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, exit_handler_impl: anytype) !HardwareProcess {
        _ = allocator;
        _ = stack_size;
        _ = process_entry;
        _ = exit_handler_impl;
    }

    pub fn init(process_allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, exit_handler_impl: anytype, arg: anytype, is_root: bool) !HardwareProcess {
        _ = is_root;
        _ = process_allocator;
        _ = stack_size;
        _ = process_entry;
        _ = exit_handler_impl;
        _ = arg;
        return HardwareProcess{
            ._sp = @ptrCast(&stack_dat),
            .stack = &[_]u8{},
            .stack_position = @ptrCast(&stack_dat),
        };
    }

    pub fn deinit(self: *HardwareProcess, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
    }

    pub fn stack_pointer(self: *const HardwareProcess) *const u8 {
        if (self._sp) |sp| {
            return sp;
        }
        return @ptrCast(&stack_dat);
    }

    pub fn get_stack_bottom(self: *const HardwareProcess) *const u8 {
        if (self._sp) |sp| {
            return @ptrFromInt(@intFromPtr(sp) + 0x1000);
        }
        return @ptrFromInt(@intFromPtr(&stack_dat) + 0x1000);
    }

    pub fn set_stack_pointer(self: *HardwareProcess, ptr: *u8, blocked_by_process: ?*HardwareProcess) void {
        _ = blocked_by_process;
        self._sp = ptr;
    }

    pub fn restore_parent_stack(self: *HardwareProcess, parent: *HardwareProcess) void {
        _ = self;
        _ = parent;
    }

    pub fn vfork(self: *HardwareProcess, allocator: std.mem.Allocator) !HardwareProcess {
        _ = allocator;
        return HardwareProcess{
            ._sp = self._sp,
            .stack = self.stack,
            .stack_position = self.stack_position,
        };
    }

    pub fn reinitialize_stack(self: *HardwareProcess, process_entry: anytype, argc: usize, argv: usize, symbol: usize, got: usize, exit_handler_impl: anytype) void {
        _ = self;
        _ = process_entry;
        _ = argc;
        _ = argv;
        _ = symbol;
        _ = got;
        _ = exit_handler_impl;
        _ = use_fpu;
    }
};

pub fn init() void {}

export fn call_main(argc: i32, argv: [*c][*c]u8, address: usize, got: usize) i32 {
    _ = argc;
    _ = argv;
    _ = address;
    _ = got;
    return 0;
}

pub var context_switch_initialized: bool = false;

pub fn initialize_context_switching() void {
    context_switch_initialized = true;
}

pub fn get_offset_of_hardware_stored_registers(use_fpu: bool) isize {
    _ = use_fpu;
    return 0;
}

// pub fn
