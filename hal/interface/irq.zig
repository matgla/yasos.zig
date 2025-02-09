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

pub fn Irq(comptime IrqImpl: anytype) type {
    return struct {
        const IrqType = IrqImpl.Type;
        const Self = @This();

        pub fn create() Self {
            return Self{};
        }

        pub fn disable(_: Self, irq: IrqType) void {
            IrqImpl.disable(irq);
        }

        pub fn enable(_: Self, irq: IrqType) void {
            IrqImpl.enable(irq);
        }

        pub fn set_priority(_: Self, irq: IrqType, priority: usize) void {
            IrqImpl.set_priority(irq, priority);
        }

        pub fn trigger_supervisor_call(_: Self, number: u32, arg: *const anyopaque, out: *anyopaque) void {
            const f: *const fn (_: u32, _: *const volatile anyopaque, _: *volatile anyopaque) callconv(.C) void = @ptrCast(&IrqImpl.trigger_supervisor_call);
            @call(.never_inline, f, .{ number, arg, out });
        }

        pub fn trigger(_: Self, irq: IrqType) void {
            IrqImpl.trigger(irq);
        }
    };
}
