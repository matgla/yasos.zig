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

// const c = @cImport({
//     @cInclude("RP2040.h");
//     @cInclude("core_cm0plus.h");
// });

const c = @import("cmsis").cmsis;
const cpu = @import("arch").Registers;

pub const Irq = struct {
    pub const Type = enum {
        systick,
        pendsv,
        supervisor_call,
    };

    pub fn disable(_: Type) void {}

    pub fn set_priority(irq: Type, priority: u32) void {
        var irq_num: c.IRQn_Type = undefined;
        switch (irq) {
            .systick => irq_num = c.SysTick_IRQn,
            .pendsv => irq_num = c.PendSV_IRQn,
            .supervisor_call => irq_num = c.SVCall_IRQn,
        }
        c.NVIC_SetPriority(irq_num, priority);
    }

    pub fn trigger_supervisor_call(_: u32, _: *const volatile anyopaque, _: *volatile anyopaque) callconv(.Naked) void {
        asm volatile (
            \\ svc 0 
            \\ bx lr
        );
    }

    pub fn trigger(irq: Type) void {
        switch (irq) {
            .pendsv => cpu.scb.icsr.write_raw(cpu.scb.icsr.raw | c.SCB_ICSR_PENDSVSET_Msk),
            else => {},
        }
    }
};
