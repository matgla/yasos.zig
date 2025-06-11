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
};
