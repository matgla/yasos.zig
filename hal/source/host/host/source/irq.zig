//
// irq.zig
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

const SystemCallHandler = *const fn (number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) callconv(.c) void;
var system_call_handler: SystemCallHandler = undefined;

pub const Irq = struct {
    pub const Type = enum {
        systick,
        pendsv,
        supervisor_call,
    };

    pub fn disable(_: Type) void {}
    pub fn set_priority(irq: Type, priority: u32) void {
        std.debug.print("TODO: implement setting priority for IRQ {s} to {d}\n", .{ @tagName(irq), priority });
    }
    pub fn trigger_supervisor_call(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) void {
        system_call_handler(number, arg, out);
    }

    pub fn trigger(irq: Type) void {
        switch (irq) {
            .pendsv => {
                std.Thread.yield() catch |err| {
                    std.debug.print("Error during context switch: {}\n", .{err});
                };
            },
            else => std.debug.print("TODO: implement triggering IRQ {s}\n", .{@tagName(irq)}),
        }
    }

    pub fn set_system_call_handler(handler: SystemCallHandler) void {
        system_call_handler = handler;
    }
};
