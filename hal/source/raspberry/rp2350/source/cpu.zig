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

const clock = @import("clocks_headers");

const ArchRegisters = @import("arch").Registers;

const sio_module = @import("sio.zig");
const sio_impl = sio_module.sio;
const Time = @import("time.zig").Time;

/// PSM `FRCE_OFF`, and its atomic set/clear aliases. Used to hard-reset core 1
/// before the launch handshake so a re-launch starts from a known state rather
/// than from wherever the previous attempt left the core.
const psm_frce_off: *volatile u32 = @ptrFromInt(0x40018000 + 0x004);
const psm_frce_off_set: *volatile u32 = @ptrFromInt(0x40018000 + 0x2000 + 0x004);
const psm_frce_off_clr: *volatile u32 = @ptrFromInt(0x40018000 + 0x3000 + 0x004);
const psm_frce_off_proc1: u32 = 1 << 24;

/// Core 1's reset entry (`startup.S`), reached via the bootrom trampoline.
extern fn _start_core1() callconv(.c) noreturn;
/// Patch one entry of the RAM vector table `crt_init` relocated VTOR to.
extern fn rp2350_install_irq_handler(irq_num: u32, handler: *const fn () callconv(.c) void) void;
/// Top of core 1's MSP stack (`linker_script.ld`).
extern var __stack_top_core1__: u8;

/// Bound on every wait in the bring-up path. Wall clock rather than an iteration
/// count, which measures the machine and not the part. Far inside the kernel's
/// own 2 s handshake timeout, so a core that never answers leaves the kernel
/// running single-core rather than hanging the boot.
const handshake_timeout_us: u64 = 100_000;

/// `SIO_IRQ_BELL`, the doorbell interrupt, from
/// `hal/libs/pico-sdk/src/rp2350/hardware_regs/include/hardware/regs/intctrl.h`.
/// Per core: each core has its own bell and its own (banked) NVIC line for it.
const sio_irq_bell: u32 = 26;

/// Which of the 8 doorbells the kernel uses for "reschedule". One is enough --
/// the kernel attaches no meaning to which bell rang -- and leaving the rest
/// unrung keeps them free for a message that does need distinguishing.
const doorbell_bit: u32 = 1 << 0;

inline fn fifo_write_ready() bool {
    return sio_impl.fifo_st.read() & sio_module.fifo_st_rdy != 0;
}

inline fn fifo_read_valid() bool {
    return sio_impl.fifo_st.read() & sio_module.fifo_st_vld != 0;
}

fn fifo_drain() void {
    while (fifo_read_valid()) {
        _ = sio_impl.fifo_rd.read();
    }
}

/// Push one word to core 1, or give up. `wfe` rather than a busy spin: the
/// FIFO raises an event on state change, so the wake is free, and the timeout
/// is what makes a missing partner survivable.
fn fifo_push(value: u32, deadline_us: u64) bool {
    while (!fifo_write_ready()) {
        if (Time.get_time_us() >= deadline_us) return false;
        asm volatile ("wfe");
    }
    sio_impl.fifo_wr.write_raw(value);
    asm volatile ("sev");
    return true;
}

fn fifo_pop(deadline_us: u64) ?u32 {
    while (!fifo_read_valid()) {
        if (Time.get_time_us() >= deadline_us) return null;
        asm volatile ("wfe");
    }
    return sio_impl.fifo_rd.read();
}

/// Hold core 1 in reset and release it, waiting for the bootrom to report in.
/// The read-back after the set forces the APB bridge to fence on any buffered
/// store, so the core really is off before the bit is cleared again.
fn reset_core1(deadline_us: u64) bool {
    psm_frce_off_set.* = psm_frce_off_proc1;
    while (psm_frce_off.* & psm_frce_off_proc1 == 0) {
        if (Time.get_time_us() >= deadline_us) return false;
    }

    psm_frce_off_clr.* = psm_frce_off_proc1;

    // Out of reset, core 1 drains its own FIFO and pushes a 0 to say so.
    const hello = fifo_pop(deadline_us) orelse return false;
    return hello == 0;
}

pub const Cpu = struct {
    pub fn name() []const u8 {
        return "RP2350";
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

    /// Interrupt the other core so it re-enters the scheduler at once. The
    /// scheduler is correct without it -- an idle core notices new work on its
    /// own SysTick -- but that is up to a full tick of latency.
    ///
    /// Doorbells are level-held and idempotent, which is what IPI semantics
    /// want. Erratum RP2350-E2: this write is at SIO `+0x180` and aliases the
    /// SIO hardware spinlocks, so it can spuriously release one. Safe only
    /// because this kernel does not use them; see the register declaration in
    /// `sio.zig`.
    pub fn ring_doorbell(core: u8) bool {
        // A core can only ring the other core's bell: `doorbell_out_set` is this
        // core's outbox and its destination is implied. Refuse a request to ring
        // our own rather than silently interrupting the wrong core.
        if (core >= number_of_cores()) return false;
        if (core == coreid()) return false;
        sio_impl.doorbell_out_set.write_raw(doorbell_bit);
        return true;
    }

    /// Acknowledge every doorbell rung on the calling core. Write-1-to-clear,
    /// and it must happen before the handler returns or the level-held interrupt
    /// re-fires. The whole word, since any bell means "reschedule".
    pub fn clear_doorbell() void {
        sio_impl.doorbell_in_clr.write_raw(0xffff);
    }

    /// Point `SIO_IRQ_BELL` at the kernel's handler. Once for both cores: they
    /// share the RAM vector table `crt_init` relocated to. Only the NVIC enable
    /// below is per core.
    pub fn install_doorbell_handler(handler: @import("hal_interface").cpu.DoorbellHandler) void {
        rp2350_install_irq_handler(sio_irq_bell, handler);
    }

    /// Let the calling core take `SIO_IRQ_BELL`. Per core, because the NVIC is
    /// banked. The handler is shared, which is fine -- it only touches the
    /// calling core's own doorbell registers.
    pub fn enable_doorbell() void {
        // Below PendSV, so the bell can preempt an idling core promptly, and
        // above nothing that matters: the handler clears the bell and pends
        // PendSV, which then tail-chains at its own (lowest) priority.
        ArchRegisters.nvic.set_priority(sio_irq_bell, 0xc0);
        ArchRegisters.nvic.enable(sio_irq_bell);
    }

    /// Release core 1 so it starts executing `_start_core1`. There is no
    /// `CPUWAIT` to clear and no `INITSVTOR1` here: core 1 comes out of reset
    /// into the bootrom, which sits in a receive loop on the inter-core FIFO and
    /// takes VTOR, SP and the entry point as messages. So there is no second
    /// vector table -- core 1 is handed core 0's live VTOR, the RAM table
    /// `crt_init` relocated to, and both cores share every handler.
    ///
    /// The protocol is six words, `{0, 0, 1, VTOR, SP, entry}`, each echoed
    /// back. A mismatched echo restarts the sequence rather than retrying the
    /// word, because the two state machines have desynchronised and a 0 is what
    /// resynchronises them -- hence the drain before each 0.
    ///
    /// Returns false rather than hanging if core 1 never answers.
    pub fn start_core(core: u8) bool {
        // Only core 1 exists to be started. Anything else is a caller bug and is
        // refused rather than turned into a reset of something else.
        if (core != 1) return false;

        const deadline_us = Time.get_time_us() + handshake_timeout_us;

        if (!reset_core1(deadline_us)) return false;

        // The thumb bit is not decoration: the bootrom loads this straight into
        // PC, and an even value faults on the first instruction. Setting it
        // unconditionally costs nothing if the relocation already did it.
        const entry: u32 = @intCast(@intFromPtr(&_start_core1) | 1);
        const stack_pointer: u32 = @intCast(@intFromPtr(&__stack_top_core1__));
        const vector_table: u32 = ArchRegisters.scb.vtor.read();

        const sequence = [_]u32{ 0, 0, 1, vector_table, stack_pointer, entry };

        var index: usize = 0;
        while (index < sequence.len) {
            if (Time.get_time_us() >= deadline_us) return false;

            const command = sequence[index];
            if (command == 0) {
                // Resynchronisation point. Clear anything core 1 has said, and
                // `sev` in case it is parked in `wfe` waiting for FIFO space.
                fifo_drain();
                asm volatile ("sev");
            }

            if (!fifo_push(command, deadline_us)) return false;
            const response = fifo_pop(deadline_us) orelse return false;

            index = if (response == command) index + 1 else 0;
        }

        return true;
    }

    /// Read the VREG VSEL value from the POWMAN register.
    /// Returns the raw 5-bit VSEL field (e.g. 11 = 1.10V, 14 = 1.25V, 21 = 1.70V).
    pub fn vreg_vsel() u8 {
        const POWMAN_VREG: *volatile u32 = @ptrFromInt(0x4010000c);
        return @intCast((POWMAN_VREG.* >> 4) & 0x1f);
    }

    pub const Registers = ArchRegisters;
};
