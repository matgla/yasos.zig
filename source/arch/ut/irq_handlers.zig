//
// irq_handlers.zig
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
    @cInclude("source/sys/include/syscall.h");
});

const ContextSwitchHandler = *const fn (lr: usize) usize;
const SystemCallHandler = *const fn (number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) callconv(.c) void;

var context_switch_handler: ?ContextSwitchHandler = null;
var system_call_handler: ?SystemCallHandler = null;

// export fn irq_svcall(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) void {
//     const lr: usize = arch.get_lr();
//     if (system_call_handler) |handler| {
//         handler(number, arg, out, lr);
//     }
// }

// export fn irq_pendsv() void {
//     const lr: usize = arch.get_lr();
//     if (context_switch_handler) |handler| {
//         handler(lr);
//     }
// }

pub fn set_context_switch_handler(handler: ContextSwitchHandler) void {
    context_switch_handler = handler;
}

pub fn call_context_switch_handler(lr: usize) usize {
    if (context_switch_handler) |handler| {
        return handler(lr);
    }
    return 0;
}

pub fn set_system_call_handler(handler: SystemCallHandler) void {
    _ = handler;
    // hal.internal.Irq.set_system_call_handler(handler);
}

export fn store_and_switch_to_next_task(lr: usize) void {
    _ = lr;
    std.Thread.yield() catch |err| {
        std.debug.print("Error during context switch: {}\n", .{err});
    };
}

pub export fn switch_to_the_next_task() void {}

export fn call_entry(address: usize, got: usize) i32 {
    _ = address;
    _ = got;
    return 0; // Placeholder for actual implementation
}

pub export fn switch_to_the_first_task() void {}
