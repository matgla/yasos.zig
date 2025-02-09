//
// sio.zig
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

const mmio = @import("../../common/mmio.zig");

const sio_address = 0xd0000000;

pub const Interp = extern struct {
    accum: [2]mmio.Mmio(u32),
    base: [3]mmio.Mmio(u32),
    pop_lane: [2]mmio.Mmio(u32),
    pop_full: mmio.Mmio(u32),
    peek_lane: [2]mmio.Mmio(u32),
    peek_full: mmio.Mmio(u32),
    ctrl_lane: [2]mmio.Mmio(u32),
    accum_add: [2]mmio.Mmio(u32),
    base_1and0: mmio.Mmio(u32),
};

pub const Sio = extern struct {
    cpuid: mmio.Mmio(u32), // 0x00
    gpio_in: mmio.Mmio(u32), // 0x04
    gpio_hi_in: mmio.Mmio(u32), // 0x08
    _reserved0: mmio.Mmio(u32), // 0x0c
    gpio_out: mmio.Mmio(u32), // 0x10
    gpio_hi_out: mmio.Mmio(u32), // 0x14
    gpio_out_set: mmio.Mmio(u32), // 0x18
    gpio_hi_out_set: mmio.Mmio(u32), // 0x1c
    gpio_out_clr: mmio.Mmio(u32), // 0x20
    gpio_hi_out_clr: mmio.Mmio(u32), // 0x24
    gpio_out_xor: mmio.Mmio(u32), // 0x28
    gpio_hi_out_xor: mmio.Mmio(u32), // 0x2c
    gpio_oe: mmio.Mmio(u32), // 0x30
    gpio_hi_oe: mmio.Mmio(u32), // 0x34,
    gpio_oe_set: mmio.Mmio(u32), // 0x38
    gpio_hi_oe_set: mmio.Mmio(u32), // 0x3c,
    gpio_oe_clr: mmio.Mmio(u32), // 0x40
    gpio_hi_oe_clr: mmio.Mmio(u32), // 0x44,
    gpio_oe_xor: mmio.Mmio(u32), // 0x48,
    gpio_hi_oe_xor: mmio.Mmio(u32), // 0x4c

    fifo_st: mmio.Mmio(u32), // 0x50
    fifo_wr: mmio.Mmio(u32), // 0x54
    fifo_rd: mmio.Mmio(u32), // 0x58
    spinlock_st: mmio.Mmio(u32), // 0x5c

    interp: [2]Interp, // 32

    spinlocks: [32]mmio.Mmio(u32), // 32
    doorbell_out_set: mmio.Mmio(u32),
    doorbell_out_clr: mmio.Mmio(u32),
    doorbell_in_set: mmio.Mmio(u32),
    doorbell_in_clr: mmio.Mmio(u32),
    peri_nonsec: mmio.Mmio(u32),
    _reserved1: [4]mmio.Mmio(u32),
    riscv_softirq: mmio.Mmio(u32),
    mtime_ctrl: mmio.Mmio(u32),
    _reserved2: [2]mmio.Mmio(u32),
    mtime: mmio.Mmio(u32),
    mtimeh: mmio.Mmio(u32),
    mtimecmp: mmio.Mmio(u32),
    mtimecmph: mmio.Mmio(u32),
    tdms_ctrl: mmio.Mmio(u32),
    tdms_wdata: mmio.Mmio(u32),
    tdms_peek_single: mmio.Mmio(u32),
    tdms_pop_single: mmio.Mmio(u32),
    tdms_peek_double_l0: mmio.Mmio(u32),
    tdms_pop_double_l0: mmio.Mmio(u32),
    tdms_peek_double_l1: mmio.Mmio(u32),
    tdms_pop_double_l1: mmio.Mmio(u32),
    tdms_peek_double_l2: mmio.Mmio(u32),
    tdms_pop_double_l2: mmio.Mmio(u32),
};

pub const sio: *volatile Sio = @ptrFromInt(sio_address);

comptime {
    const std = @import("std");
    var buf: [30]u8 = undefined;
    if (@sizeOf(Interp) != 64) @compileError("Interp has incorrect size: " ++ (std.fmt.bufPrint(&buf, "{d}", .{@sizeOf(Interp)}) catch "unknown"));
    if (@sizeOf(Sio) != 0x1e8) @compileError("SIO has incorrect size: " ++ (std.fmt.bufPrint(&buf, "{d}", .{@sizeOf(Sio)}) catch "unknown"));
}
