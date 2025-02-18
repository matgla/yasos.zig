//
// armv6-m_registers.zig
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

const mmio = @import("hal").mmio;

pub const SystemControlBlock = extern struct {
    cpuid: mmio.Mmio(packed struct(u32) {
        revision: u4,
        partno: u12,
        architecture: u4,
        variant: u4,
        implementer: u8,
    }),
    icsr: mmio.Mmio(u32),
};

pub const SysTick = extern struct {
    ctrl: mmio.Mmio(u32),
    load: mmio.Mmio(u32),
    val: mmio.Mmio(u32),
    calib: mmio.Mmio(u32),
};

pub const CpuCpacr = extern struct {
    cpacr: mmio.Mmio(packed struct(u32) {
        cp0: u2,
        cp1: u2,
        cp2: u2,
        cp3: u2,
        cp4: u2,
        cp5: u2,
        cp6: u2,
        cp7: u2,
        _res1: u4,
        cp10: u2,
        cp11: u2,
        _res2: u8,
    }),
};

pub const Registers = struct {
    pub const ppb_base: u32 = 0xe0000000;
    pub const scb_base: u32 = ppb_base + 0xed00;
    pub const scs_base: u32 = ppb_base + 0xe000;

    pub const scb: *volatile SystemControlBlock = @ptrFromInt(scb_base);

    pub const systick_base: u32 = scs_base + 0x0010;
    pub const systick: *volatile SysTick = @ptrFromInt(systick_base);

    pub const cpacr: *volatile CpuCpacr = @ptrFromInt(ppb_base + 0xed88);
};
