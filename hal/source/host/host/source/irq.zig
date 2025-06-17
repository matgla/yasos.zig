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
    pub fn trigger_supervisor_call(_: u32, _: *const volatile anyopaque, _: *volatile anyopaque) void {
        std.debug.print("TODO: implement triggering supervisor call\n", .{});
    }

    pub fn trigger(irq: Type) void {
        switch (irq) {
            else => std.debug.print("TODO: implement triggering IRQ {s}\n", .{@tagName(irq)}),
        }
    }
};
