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

const hal = @import("hal");

const ContextSwitchHandler = *const fn (lr: usize) void;
const SystemCallHandler = *const fn (number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) void;

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

pub fn set_system_call_handler(handler: SystemCallHandler) void {
    hal.internal.Irq.set_system_call_handler(handler);
}

export fn store_and_switch_to_next_task(lr: usize) void {
    _ = lr;
    std.Thread.yield() catch |err| {
        std.debug.print("Error during context switch: {}\n", .{err});
    };
}

export fn switch_to_next_task() void {
    std.Thread.yield() catch |err| {
        std.debug.print("Error during context switch: {}\n", .{err});
    };
}

export fn call_main(argc: i32, argv: [*c][*c]u8, address: usize, got: usize) i32 {
    _ = argc;
    _ = argv;
    _ = address;
    _ = got;
    return 0; // Placeholder for actual implementation
}

export fn call_entry(address: usize, got: usize) i32 {
    _ = address;
    _ = got;
    return 0; // Placeholder for actual implementation
}

export fn reload_current_task() void {
    // Placeholder for actual implementation
}
