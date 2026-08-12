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

const c = @import("cmsis").cmsis;

pub const SystemControlBlock = extern struct {
    cpuid: mmio.Mmio(packed struct(u32) {
        revision: u4,
        partno: u12,
        architecture: u4,
        variant: u4,
        implementer: u8,
    }),
    icsr: mmio.Mmio(u32),
    vtor: mmio.Mmio(u32),
    aircr: mmio.Mmio(packed struct(u32) {
        reserved0: u1,
        vectclractive: u1,
        sysresetreq: u1,
        sysresetreqs: u1,
        dit: u1,
        iesb: u1,
        reserved1: u2,
        prigroup: u3,
        reserved2: u2,
        bfhfnmins: u1,
        pris: u1,
        endianess: u1,
        vectkey: u16,
    }),
    scr: mmio.Mmio(packed struct(u32) {
        reserved0: u1,
        sleeponexit: u1,
        sleepdeep: u1,
        sleepdeps: u1,
        sevonpend: u1,
        reserved1: u27,
    }),
    ccr: mmio.Mmio(packed struct(u32) {
        reserved0: u1,
        usersetmpend: u1,
        reserved1: u1,
        unaligntrp: u1,
        div0trp: u1,
        reserved2: u3,
        bfhfnmign: u1,
        reserved3: u1,
        stkofhfnnmign: u1,
        reserved4: u5,
        dc: u1,
        ic: u1,
        bp: u1,
        reserved5: u13,
    }),
    shpr: [12]u8,
    shcsr: mmio.Mmio(u32),
    cfsr: mmio.Mmio(packed struct(u32) {
        mmfsr: u8,
        bfsr: u8,
        ufsr: u16,
    }),
    hfsr: mmio.Mmio(u32),
    reserved0: u32,
    mmfar: mmio.Mmio(u32),
    bfar: mmio.Mmio(u32),
    _afsr: mmio.Mmio(u32),
    reserved1: [18]u32,
    cpacr: mmio.Mmio(u32),
    nsacr: mmio.Mmio(u32),
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
// ARMv8-M Memory Protection Unit (PMSAv8). Region attributes are split between
// RBAR (base, shareability, access permission, execute-never) and RLAR (limit,
// MAIR attribute index, enable), with the actual memory attributes living in the
// indirection registers MAIR0/MAIR1.
pub const Mpu = extern struct {
    type: mmio.Mmio(packed struct(u32) {
        separate: u1,
        reserved0: u7,
        dregion: u8,
        reserved1: u16,
    }),
    ctrl: mmio.Mmio(packed struct(u32) {
        enable: u1,
        hfnmiena: u1,
        privdefena: u1,
        reserved0: u29,
    }),
    rnr: mmio.Mmio(u32),
    rbar: mmio.Mmio(u32),
    rlar: mmio.Mmio(u32),
    rbar_a1: mmio.Mmio(u32),
    rlar_a1: mmio.Mmio(u32),
    rbar_a2: mmio.Mmio(u32),
    rlar_a2: mmio.Mmio(u32),
    rbar_a3: mmio.Mmio(u32),
    rlar_a3: mmio.Mmio(u32),
    reserved0: u32,
    mair0: mmio.Mmio(u32),
    mair1: mmio.Mmio(u32),
};

pub const NVIC = extern struct {
    iser: [16]u32,
    reserved0: [16]u32,
    icer: [16]u32,
    reserved1: [16]u32,
    ispr: [16]u32,
    reserved2: [16]u32,
    icpr: [16]u32,
    reserved3: [16]u32,
    iabr: [16]u32,
    reserved4: [16]u32,
    itns: [16]u32,
    reserved5: [16]u32,
    ipr: [496]u8,
    reserved6: [580]u32,
    stir: u32,

    /// Unmask an external interrupt on the calling core. The NVIC is banked per
    /// core, so each core has to issue this for itself; the SMP doorbell relies
    /// on that -- one shared handler, enabled separately on each core.
    ///
    /// `iser` is write-1-to-set, so a single bit enables one interrupt without
    /// disturbing the others; a read-modify-write would race the other core.
    pub fn enable(self: *volatile NVIC, irq_num: u32) void {
        self.iser[irq_num >> 5] = @as(u32, 1) << @intCast(irq_num & 0x1f);
    }

    pub fn set_priority(self: *volatile NVIC, irq_num: i32, priority: u32) void {
        const priority_mask: u8 = @as(u8, @truncate((priority << (8 - c.__NVIC_PRIO_BITS))));
        if (irq_num > 0) {
            self.ipr[@intCast(irq_num)] = priority_mask;
        } else {
            const num: u32 = @intCast((irq_num & 0xf) - 4);
            Registers.scb.shpr[num] = priority_mask;
        }
    }
};

pub const Registers = struct {
    pub const ppb_base: u32 = 0xe0000000;
    pub const scb_base: u32 = ppb_base + 0xed00;
    pub const scs_base: u32 = ppb_base + 0xe000;

    pub const scb: *volatile SystemControlBlock = @ptrFromInt(scb_base);

    /// Auxiliary Control Register (SCS + 0x008). Implementation-defined; these
    /// are the Cortex-M33's bits.
    ///
    /// `EXTEXCLALL` is the one that matters: with it clear, an exclusive to an
    /// address not covered by an enabled MPU region is handled by the core's
    /// local monitor only, so `ldrex`/`strex` on two cores never see each other
    /// and every lock built on them silently stops excluding. Per core, so it
    /// has to be set on each. Note the "with no MPU" in the field name -- once
    /// an enabled region covers the address, its Shareable attribute decides.
    pub const actlr: *volatile mmio.Mmio(packed struct(u32) {
        dismcycint: u1, // 0
        reserved0: u1, // 1
        disfold: u1, // 2
        reserved1: u6, // 3..8
        disoofp: u1, // 9
        fpexcodis: u1, // 10
        reserved2: u1, // 11
        disitmatbflush: u1, // 12
        reserved3: u16, // 13..28
        extexclall: u1, // 29
        reserved4: u2, // 30..31
    }) = @ptrFromInt(scs_base + 0x008);

    pub const systick_base: u32 = scs_base + 0x0010;
    pub const systick: *volatile SysTick = @ptrFromInt(systick_base);

    pub const cpacr: *volatile CpuCpacr = @ptrFromInt(ppb_base + 0xed88);

    pub const mpu_base: u32 = scs_base + 0x0d90;
    pub const mpu: *volatile Mpu = @ptrFromInt(mpu_base);

    pub const nvic_base: u32 = scs_base + 0x0100;
    pub const nvic: *volatile NVIC = @ptrFromInt(nvic_base);
};
