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

const mmio = @import("raspberry_common").mmio;

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

/// The RP2350 SIO block. Not the RP2040 layout: GPIO is interleaved low/high
/// from `+0x14` onwards, and there is no divider -- the Arm cores have
/// `SDIV`/`UDIV`, so `+0x60`..`+0x7c` is reserved.
///
/// An RP2040-shaped struct happens to place `cpuid` and `spinlocks` correctly,
/// since both layouts have 32 words ahead of `INTERP0`, so a `@sizeOf` check
/// passes while everything between them is silently wrong. Hence the per-field
/// `@offsetOf` asserts below.
pub const Sio = extern struct {
    cpuid: mmio.Mmio(u32),
    gpio_in: mmio.Mmio(u32),
    gpio_hi_in: mmio.Mmio(u32),
    _reserved0: mmio.Mmio(u32),

    gpio_out: mmio.Mmio(u32),
    gpio_hi_out: mmio.Mmio(u32),
    gpio_out_set: mmio.Mmio(u32),
    gpio_hi_out_set: mmio.Mmio(u32),
    gpio_out_clr: mmio.Mmio(u32),
    gpio_hi_out_clr: mmio.Mmio(u32),
    gpio_out_xor: mmio.Mmio(u32),
    gpio_hi_out_xor: mmio.Mmio(u32),

    gpio_oe: mmio.Mmio(u32),
    gpio_hi_oe: mmio.Mmio(u32),
    gpio_oe_set: mmio.Mmio(u32),
    gpio_hi_oe_set: mmio.Mmio(u32),
    gpio_oe_clr: mmio.Mmio(u32),
    gpio_hi_oe_clr: mmio.Mmio(u32),
    gpio_oe_xor: mmio.Mmio(u32),
    gpio_hi_oe_xor: mmio.Mmio(u32),

    /// Inter-core FIFO status. See `fifo_st_*` below for the bits.
    fifo_st: mmio.Mmio(u32),
    /// Push to the *other* core's receive FIFO. Writing when full sets `WOF`.
    fifo_wr: mmio.Mmio(u32),
    /// Pop from this core's receive FIFO. Reading when empty sets `ROE`.
    fifo_rd: mmio.Mmio(u32),
    spinlock_st: mmio.Mmio(u32),

    /// `+0x60`..`+0x7c`: the RP2040's `DIV_*` registers, reserved here.
    _reserved1: [8]mmio.Mmio(u32),

    interp: [2]Interp,
    spinlocks: [32]mmio.Mmio(u32),

    /// Doorbells -- the RP2350's cross-core interrupt, absent on the RP2040.
    /// Writing a bit to `doorbell_out_set` rings it on the other core, where it
    /// appears in `doorbell_in_*` and raises `SIO_IRQ_BELL` (IRQ 26). Level-held
    /// and idempotent; the receiver acknowledges via `doorbell_in_clr`.
    ///
    /// Erratum RP2350-E2 applies to every register from here on. Quoting
    /// pico-sdk `hardware/sync.h`: "writes to new SIO registers above an offset
    /// of +0x180 alias the spinlocks, causing spurious lock releases." This
    /// kernel is safe only because it does not use them -- do not introduce a
    /// SIO spinlock while doorbells are in use.
    doorbell_out_set: mmio.Mmio(u32),
    doorbell_out_clr: mmio.Mmio(u32),
    doorbell_in_set: mmio.Mmio(u32),
    doorbell_in_clr: mmio.Mmio(u32),

    peri_nonsec: mmio.Mmio(u32),
};

/// `FIFO_ST` bits. `RDY`/`VLD` are the two the launch handshake spins on.
pub const fifo_st_vld: u32 = 1 << 0; // this core's RX FIFO has data
pub const fifo_st_rdy: u32 = 1 << 1; // this core's TX FIFO has room
pub const fifo_st_wof: u32 = 1 << 2; // write-on-full happened (W1C)
pub const fifo_st_roe: u32 = 1 << 3; // read-on-empty happened (W1C)

pub const sio: *volatile Sio = @ptrFromInt(sio_address);

comptime {
    const std = @import("std");

    if (@sizeOf(Interp) != 64) @compileError("Interp has incorrect size");

    // Per-field rather than a single @sizeOf, because the RP2040-shaped layout
    // this replaces had the *same* total size with the middle rearranged.
    // Offsets are from rp2350 hardware/regs/sio.h.
    const expected = .{
        .{ "cpuid", 0x000 },
        .{ "gpio_in", 0x004 },
        .{ "gpio_hi_in", 0x008 },
        .{ "gpio_out", 0x010 },
        .{ "gpio_hi_out", 0x014 },
        .{ "gpio_out_set", 0x018 },
        .{ "gpio_hi_out_set", 0x01c },
        .{ "gpio_out_clr", 0x020 },
        .{ "gpio_out_xor", 0x028 },
        .{ "gpio_oe", 0x030 },
        .{ "gpio_hi_oe", 0x034 },
        .{ "gpio_oe_set", 0x038 },
        .{ "gpio_oe_clr", 0x040 },
        .{ "gpio_oe_xor", 0x048 },
        .{ "gpio_hi_oe_xor", 0x04c },
        .{ "fifo_st", 0x050 },
        .{ "fifo_wr", 0x054 },
        .{ "fifo_rd", 0x058 },
        .{ "spinlock_st", 0x05c },
        .{ "interp", 0x080 },
        .{ "spinlocks", 0x100 },
        .{ "doorbell_out_set", 0x180 },
        .{ "doorbell_out_clr", 0x184 },
        .{ "doorbell_in_set", 0x188 },
        .{ "doorbell_in_clr", 0x18c },
        .{ "peri_nonsec", 0x190 },
    };

    for (expected) |entry| {
        if (@offsetOf(Sio, entry[0]) != entry[1]) {
            var buf: [96]u8 = undefined;
            @compileError("SIO." ++ entry[0] ++ " is at the wrong offset: " ++
                (std.fmt.bufPrint(&buf, "{x} instead of {x}", .{ @offsetOf(Sio, entry[0]), entry[1] }) catch "unknown"));
        }
    }
}
