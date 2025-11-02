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

const c = @import("libc_imports").c;

pub const IrqStub = struct {
    pub const Action = *const fn (id: u32, arg: *const volatile anyopaque, result: *volatile anyopaque) callconv(.c) void;
    pub const IrqAction = *const fn () void;

    pub var calls: [c.SYSCALL_COUNT]u32 = .{0} ** c.SYSCALL_COUNT;
    pub var actions: [c.SYSCALL_COUNT]?Action = .{null} ** c.SYSCALL_COUNT;

    pub const Type = enum(u4) {
        systick,
        pendsv,
        supervisor_call,
    };

    const IrqLen = @typeInfo(Type).@"enum".fields.len;
    pub var irq_actions: [IrqLen]?IrqAction = .{null} ** IrqLen;
    pub var irq_disable_mask: std.StaticBitSet(IrqLen) = std.StaticBitSet(IrqLen).initEmpty();

    pub fn set_action(id: u32, action: Action) void {
        actions[id] = action;
    }

    pub fn set_irq_action(irq: Type, action: IrqAction) void {
        irq_actions[@intFromEnum(irq)] = action;
    }

    pub fn clear() void {
        for (0..c.SYSCALL_COUNT) |idx| {
            calls[idx] = 0;
            actions[idx] = null;
        }

        for (0..IrqLen) |idx| {
            irq_actions[idx] = null;
        }

        irq_disable_mask = std.StaticBitSet(IrqLen).initEmpty();
    }

    pub fn disable(t: Type) void {
        irq_disable_mask.set(@intFromEnum(t));
    }

    pub fn set_priority(_: Type, _: u32) void {}

    pub fn trigger_supervisor_call(id: u32, arg: *const volatile anyopaque, result: *volatile anyopaque) callconv(.c) void {
        if (actions[id]) |action| {
            action(id, arg, result);
            return;
        } else {
            calls[id] += 1;
        }
    }

    pub fn trigger(t: Type) void {
        if (irq_actions[@intFromEnum(t)]) |action| {
            if (irq_disable_mask.isSet(@intFromEnum(t))) {
                return;
            }
            irq_disable_mask.set(@intFromEnum(t));
            action();
            irq_disable_mask.unset(@intFromEnum(t));
        }
    }

    pub fn enter_critical_section() void {}

    pub fn leave_critical_section() void {}
};
