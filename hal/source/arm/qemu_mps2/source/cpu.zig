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

const ArchRegisters = @import("arch").Registers;

/// SCB AIRCR, for `Cpu.reset`. Writes need the key in the top half.
const aircr: *volatile u32 = @ptrFromInt(0xe000ed0c);
const aircr_vectkey: u32 = 0x05fa << 16;
const aircr_sysresetreq: u32 = 1 << 2;

pub const Cpu = struct {
    pub const Registers = ArchRegisters;

    pub fn name() []const u8 {
        return "Cortex-M33 (MPS2-AN505)";
    }

    // QEMU MPS2-AN505 SYSCLK is 25 MHz. Used for the 1 ms SysTick reload and
    // the hardware splash; not performance critical under emulation.
    pub fn frequency() u64 {
        return 25_000_000;
    }

    pub fn number_of_cores() u8 {
        return 1;
    }

    pub fn coreid() u8 {
        return 0;
    }

    pub fn set_stack_guard(_: ?*const u8) void {}

    /// SYSRESETREQ: QEMU turns it into a reset of the whole machine, which
    /// loads the kernel image again and boots it from the top.
    pub fn reset() noreturn {
        aircr.* = aircr_vectkey | aircr_sysresetreq;
        asm volatile ("dsb" ::: .{ .memory = true });
        while (true) asm volatile ("wfi");
    }

    /// Switch the emulator off: semihosting SYS_EXIT_EXTENDED with "application
    /// exit", status 0. Every launch script runs QEMU with semihosting on.
    pub fn halt() noreturn {
        const block = [2]usize{ 0x20026, 0 };
        while (true) {
            asm volatile ("bkpt 0xAB"
                :
                : [op] "{r0}" (@as(usize, 0x20)),
                  [blk] "{r1}" (@intFromPtr(&block)),
                : .{ .memory = true });
        }
    }
};
