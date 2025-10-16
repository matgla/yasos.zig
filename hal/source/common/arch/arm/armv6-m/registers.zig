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

pub const NVIC = extern struct {
    iser: mmio.Mmio([16]u32),
    reserved0: mmio.Mmio([16]u32),
    icer: mmio.Mmio([16]u32),
    reserved1: mmio.Mmio([16]u32),
    ispr: mmio.Mmio([16]u32),
    reserved2: mmio.Mmio([16]u32),
    icpr: mmio.Mmio([16]u32),
    reserved3: mmio.Mmio([16]u32),
    iabr: mmio.Mmio([16]u32),
    reserved4: mmio.Mmio([16]u32),
    itns: mmio.Mmio([16]u32),
    reserved5: mmio.Mmio([16]u32),
    ipr: mmio.Mmio([496]u8),
    reserved6: mmio.Mmio([580]u32),
    stir: mmio.Mmio(u32),
};

pub const Registers = struct {
    pub const ppb_base: u32 = 0xe0000000;
    pub const scb_base: u32 = ppb_base + 0xed00;
    pub const scs_base: u32 = ppb_base + 0xe000;

    pub const scb: *volatile SystemControlBlock = @ptrFromInt(scb_base);

    pub const systick_base: u32 = scs_base + 0x0010;
    pub const systick: *volatile SysTick = @ptrFromInt(systick_base);

    pub const nvic_base: u32 = scs_base + 0x0100;
    pub const nvic: *volatile NVIC = @ptrFromInt(nvic_base);
};
