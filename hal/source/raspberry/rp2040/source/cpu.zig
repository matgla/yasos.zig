//
// cpu.zig
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

const clock = @cImport({
    @cInclude("hardware/clocks.h");
});

const RegistersImplementation = @import("cortex-m0plus").Registers;
const sio_impl = @import("sio.zig").sio;

pub const Cpu = struct {
    pub fn name() []const u8 {
        return "RP2040";
    }

    pub fn frequency() u64 {
        return clock.clock_get_hz(clock.clk_sys);
    }

    pub fn number_of_cores() u8 {
        return 2;
    }

    pub fn coreid() u8 {
        return @intCast(sio_impl.cpuid.read());
    }

    /// The watchdog's forced reset, as pico-sdk's `watchdog_reboot(0, 0, 0)`:
    /// everything but the oscillators, and scratch 4 cleared so the boot ROM
    /// boots from flash. SYSRESETREQ would restart the cores alone.
    pub fn reset() noreturn {
        const watchdog_base: usize = 0x40058000;
        const ctrl_set: *volatile u32 = @ptrFromInt(watchdog_base + 0x2000);
        const ctrl_clr: *volatile u32 = @ptrFromInt(watchdog_base + 0x3000);
        const scratch4: *volatile u32 = @ptrFromInt(watchdog_base + 0x1c);
        const psm_wdsel_set: *volatile u32 = @ptrFromInt(0x40010000 + 0x2000 + 0x008);
        ctrl_clr.* = 1 << 30; // ENABLE
        scratch4.* = 0;
        psm_wdsel_set.* = 0x0001ffff & ~@as(u32, 0x3); // all but ROSC, XOSC
        ctrl_set.* = 1 << 31; // TRIGGER
        while (true) asm volatile ("wfi");
    }

    pub const Registers = RegistersImplementation;
};
