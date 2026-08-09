//
// system_stubs.zig
//
// Copyright (C) 2024 Mateusz Stadnik <matgla@live.com>
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

const c = @import("crt_headers");

const config = @import("config").cpu;
const flash_config = @import("config").flash;

const requested_freq_mhz: u32 = if (@hasDecl(config, "clock_frequency_mhz"))
    config.clock_frequency_mhz
else
    150;

const PllParams = struct {
    vco_freq: u32,
    postdiv1: c_uint,
    postdiv2: c_uint,
    actual_freq_mhz: u32,
};

// Find the highest achievable PLL frequency <= requested_mhz.
// XOSC = 12 MHz, VCO range 750–1600 MHz, postdiv1/2 in [1..7], pd2 <= pd1.
fn computePllParams(requested_mhz: u32) PllParams {
    @setEvalBranchQuota(100_000);
    const xosc_khz: u32 = 12_000;
    const vco_min_khz: u32 = 750_000;
    const vco_max_khz: u32 = 1_600_000;
    const max_khz: u32 = requested_mhz * 1_000;

    var best: PllParams = .{ .vco_freq = 0, .postdiv1 = 0, .postdiv2 = 0, .actual_freq_mhz = 0 };

    var fbdiv: u32 = 320;
    while (fbdiv >= 16) : (fbdiv -= 1) {
        const vco_khz = fbdiv * xosc_khz;
        if (vco_khz < vco_min_khz or vco_khz > vco_max_khz) continue;
        var pd1: u32 = 7;
        while (pd1 >= 1) : (pd1 -= 1) {
            var pd2: u32 = pd1;
            while (pd2 >= 1) : (pd2 -= 1) {
                if ((vco_khz % (pd1 * pd2)) != 0) continue;
                const out_khz = vco_khz / (pd1 * pd2);
                if (out_khz > max_khz) continue;
                if (out_khz > best.actual_freq_mhz * 1_000) {
                    best = .{
                        .vco_freq = vco_khz * 1_000,
                        .postdiv1 = pd1,
                        .postdiv2 = pd2,
                        .actual_freq_mhz = out_khz / 1_000,
                    };
                }
            }
        }
    }
    if (best.actual_freq_mhz == 0) {
        @compileError("Cannot find valid PLL parameters for the requested CPU frequency");
    }
    return best;
}

const pll_params = computePllParams(requested_freq_mhz);
const clock_freq_mhz: u32 = pll_params.actual_freq_mhz;

// POWMAN VREG VSEL -> regulator output in millivolts (RP2350 datasheet). The
// scale is 50 mV per step only up to vsel 15 (1.30 V, the top of the in-spec
// range); above that it is irregular, and from vsel 23 it steps in 100 mV. This
// is the same table /proc and the boot banner print from
// (source/kernel/dump_hardware.zig).
//
// Selection below is written in millivolts and converted here on purpose. The
// codes used to be written raw with the voltage in a trailing comment, and the
// comments were wrong for exactly the region that matters: 0x190 was labelled
// "2.00V" when it is 2.10 V, and an intended "one 50 mV step" above it landed on
// 0x1a0 = 2.20 V, because no 50 mV step exists up there. A code and its stated
// voltage cannot disagree if only one of them is written by hand.
const vsel_mv = [32]u16{
    550,  600,  650,  700,  750,  800,  850,  900, // 0-7
    950,  1000, 1050, 1100, 1150, 1200, 1250, 1300, // 8-15
    1350, 1400, 1500, 1600, 1650, 1700, 1800, 1900, // 16-23
    2000, 2100, 2200, 2300, 2400, 2500, 2600, 3300, // 24-31
};

/// POWMAN VREG register value delivering exactly `mv`, or a compile error if the
/// regulator has no such step. Bypasses the SDK's 1.3 V clamp.
fn vregCodeForMv(comptime mv: u16) u32 {
    for (vsel_mv, 0..) |step_mv, vsel| {
        if (step_mv == mv) return @as(u32, @intCast(vsel)) << 4;
    }
    @compileError("POWMAN VREG has no step at the requested core voltage; pick one of the values in vsel_mv");
}

/// CONFIG_CPU_CORE_VOLTAGE_MV, or 0 to derive the voltage from the frequency.
const core_voltage_override_mv: u16 = if (@hasDecl(config, "core_voltage_mv"))
    config.core_voltage_mv
else
    0;

// Based on MichaelBell's RP2350 overclocking data with ~10% safety margin.
fn requiredVregCode() u32 {
    if (core_voltage_override_mv != 0) return vregCodeForMv(core_voltage_override_mv);
    // The bottom band is 1200 mV rather than the 1100 mV nominal because of
    // PLL_USB, not the core: at 1100 mV it cannot hold its 1200 MHz VCO on the
    // pico_plus2 rig, so clk_peri lands near 40 MHz and the console runs at a
    // baud nobody is listening at (see the clk_peri cross-check in _start).
    // That is a supply floor for the PLL, so it applies to every clock in the
    // band, not just the 150 MHz one it was found at.
    if (clock_freq_mhz <= 300) return vregCodeForMv(1200);
    if (clock_freq_mhz <= 324) return vregCodeForMv(1250);
    if (clock_freq_mhz <= 348) return vregCodeForMv(1300);
    if (clock_freq_mhz <= 370) return vregCodeForMv(1350);
    if (clock_freq_mhz <= 384) return vregCodeForMv(1400);
    if (clock_freq_mhz <= 424) return vregCodeForMv(1500);
    if (clock_freq_mhz <= 452) return vregCodeForMv(1600);
    if (clock_freq_mhz <= 480) return vregCodeForMv(1700);
    if (clock_freq_mhz <= 512) return vregCodeForMv(1800);
    if (clock_freq_mhz <= 560) return vregCodeForMv(1900);
    // 600+ MHz was marginal at 1.90 V (intermittent PSRAM/core read corruption
    // that disappeared at 150 MHz); 2.10 V is what fixed it, and 618 MHz has run
    // on it since.
    //
    // Everything above 618 MHz keeps that same 2.10 V deliberately. The next
    // step the regulator offers is 2.20 V — there is nothing in between — and
    // +100 mV on a core whose nominal supply is 1.10 V is not a step to take on
    // the theory that more clock needs more volts. If a higher clock is
    // unstable, lower the clock first; this is already far enough outside spec
    // that the failure mode is silent wrong data rather than a clean fault, and
    // the 618 MHz investigation found it ~80% intermittent, so a single clean
    // run proves nothing either way.
    return vregCodeForMv(2100);
}

const flash_max_sck_mhz: u32 = flash_config.xip_max_frequency_hz / 1_000_000;

/// Chip-select high time to enforce between XIP reads. Boards that do not name
/// their part's read-side figure keep 50 ns, which is the erase/program one and
/// safe for any part -- see the MIN_DESELECT comment in computeQmiConfig.
const flash_deselect_ns: u32 = if (@hasDecl(flash_config, "xip_deselect_ns"))
    flash_config.xip_deselect_ns
else
    50;

const sio = @import("../source/sio.zig").sio;

const cpu = @import("arch").Registers;

extern var __data_start__: u8;
extern var __data_end__: u8;
extern var __data_start_flash__: u8;

extern var __bss_start__: u8;
extern var __bss_end__: u8;

fn initialize_data() void {
    const data_start: [*]u8 = @ptrCast(&__data_start__);
    const data_end: [*]u8 = @ptrCast(&__data_end__);
    const data_len = @intFromPtr(data_end) - @intFromPtr(data_start);
    const data_src: [*]const u8 = @ptrCast(&__data_start_flash__);

    @memcpy(data_start[0..data_len], data_src[0..data_len]);
}

fn initialize_bss() void {
    const bss_start: [*]u8 = @ptrCast(&__bss_start__);
    const bss_end: [*]u8 = @ptrCast(&__bss_end__);
    const bss_length = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..bss_length], 0);
}

extern fn __libc_init_array() void;

fn initialize_libc_constructors() void {
    __libc_init_array();
}

export fn _init() void {}

const ram_vector_table_size: usize = c.VTABLE_FIRST_IRQ + c.PICO_NUM_VTABLE_IRQS;
var ram_vector_table: [ram_vector_table_size]usize linksection(".ram_vector_table") = @splat(0);

extern var __vectors_start: usize;
extern var __vectors_end: usize;

fn initialize_ram_vector_table() void {
    const vectors_start: *usize = @ptrCast(&__vectors_start);
    const vectors_end: *usize = @ptrCast(&__vectors_end);
    const bytes = @intFromPtr(vectors_end) - @intFromPtr(vectors_start);
    const src: [*]const u8 = @ptrCast(vectors_start);
    const dst: [*]u8 = @ptrCast(&ram_vector_table);
    @memcpy(dst[0..bytes], src[0..bytes]);
    cpu.scb.vtor.write(@intFromPtr(&ram_vector_table));
}

pub const IrqHandler = *const fn () callconv(.c) void;

export fn rp2350_install_irq_handler(irq_num: u32, handler: IrqHandler) void {
    const vector_index: usize = @intCast(@as(u32, @intCast(c.VTABLE_FIRST_IRQ)) + irq_num);
    ram_vector_table[vector_index] = @intFromPtr(handler);
    asm volatile (
        \\ dsb sy
        \\ isb sy
        ::: .{ .memory = true });
}

export fn crt_init() void {
    c.reset_block(~(c.RESETS_RESET_IO_QSPI_BITS | c.RESETS_RESET_PADS_QSPI_BITS |
        c.RESETS_RESET_PLL_USB_BITS | c.RESETS_RESET_USBCTRL_BITS | c.RESETS_RESET_SYSCFG_BITS |
        c.RESETS_RESET_PLL_SYS_BITS));

    c.unreset_block_wait(c.RESETS_RESET_BITS &
        ~(c.RESETS_RESET_ADC_BITS | c.RESETS_RESET_HSTX_BITS | c.RESETS_RESET_SPI0_BITS |
            c.RESETS_RESET_SPI1_BITS | c.RESETS_RESET_UART0_BITS |
            c.RESETS_RESET_UART1_BITS | c.RESETS_RESET_USBCTRL_BITS));

    initialize_ram_vector_table();
    initialize_data();
    initialize_bss();
    initialize_libc_constructors();

    // Always restore VREG to default 1.10V first — the POWMAN register
    // persists across warm resets and we have no power-cycle capability.
    c.overclock_set_voltage(0x0b0); // 1.10V

    // Always boot at 150 MHz — overclock is applied later via
    // apply_overclock() after UART is available for debug output.
    c.runtime_init_clocks();

    if (config.has_fpu and config.use_fpu) {
        cpu.cpacr.cpacr.update(.{
            .cp0 = 0x3,
            .cp4 = 0x3,
            .cp10 = 0x3,
        });
    }
    // release all spinlocks
    for (&sio.spinlocks) |*lock| {
        lock.write(1);
    }

    // c.alarm_pool_init_default();
}

/// Apply overclock + QSPI configuration. Call after UART is initialized
/// so debug output is available. Returns 0 on success, 1 if skipped (already at 150 MHz).
///
/// Matches overclock_test main() sequence 1:1.
export fn apply_overclock() u32 {
    const vreg_code: u32 = comptime requiredVregCode();

    // Always restore VREG to the correct voltage for the configured frequency,
    // even at 150 MHz — POWMAN persists across warm resets.
    c.overclock_set_voltage(vreg_code);
    // Extra settle time — overclock_set_voltage has ~3ms delay at 150 MHz.
    // The working test uses sleep_ms(100). Add ~100ms: 150MHz / 2 cyc * 0.1s = 7.5M
    c.overclock_delay_cycles(7_500_000);

    // NOTE: Previously we early-returned at 150 MHz (the boot frequency) on the
    // assumption that no reconfiguration was needed. That left clk_peri on its
    // boot source instead of PLL_USB and left flash/PSRAM on bootrom timing,
    // which fails to boot on the current pico_plus2 config (16 MB flash, 84 MHz
    // PSRAM). Run the full, proven overclock sequence at 150 MHz too: re-locking
    // PLL_SYS to 150 MHz via overclock_apply() is the same RAM-resident sequence
    // used for 618 MHz (which itself starts from the 150 MHz boot PLL), so it is
    // safe, and it gives a consistent clk_peri/flash setup at every frequency.

    const target_khz: u32 = comptime pll_params.actual_freq_mhz * 1000;

    // Step 1: Enable QE bit at safe boot clock (matches test)
    _ = c.overclock_flash_enable_qe();

    // Step 2: Compute QMI M0 config for Quad I/O Fast Read (EBh) (matches test)
    const qmi_cfg = computeQmiConfig(target_khz, flash_max_sck_mhz);

    // Step 3: Atomic PLL + QMI switch from RAM (matches test overclock_from_ram)
    c.overclock_apply(
        pll_params.vco_freq,
        pll_params.postdiv1,
        pll_params.postdiv2,
        qmi_cfg.timing,
        qmi_cfg.rfmt,
        qmi_cfg.rcmd,
    );

    // Step 4: Switch clk_peri to PLL_USB (48 MHz) for stable UART (matches test)
    _ = c.clock_configure(
        c.clk_peri,
        0,
        c.CLOCKS_CLK_PERI_CTRL_AUXSRC_VALUE_CLKSRC_PLL_USB,
        clk_peri_expected_khz * 1000,
        clk_peri_expected_khz * 1000,
    );

    // Step 5: Update SDK's cached frequencies (matches test)
    c.clock_set_reported_hz(c.clk_sys, target_khz * 1000);

    // Step 6: check that the clocks are what we just told the SDK they are.
    //
    // Everything downstream trusts the *reported* frequencies rather than the
    // hardware: uart_set_baudrate() derives IBRD/FBRD from clock_get_hz(clk_peri),
    // so a PLL that quietly came up short does not fault, it just shifts the
    // console to a bit rate nobody is listening at. That failure is
    // indistinguishable from a dead board — the smoke harness sees garbage and
    // runs the whole reset / power-cycle / reflash ladder against a target that
    // is booting perfectly well.
    //
    // It is not hypothetical: at 150 MHz requiredVregCode() used to pick 1100 mV,
    // and on the pico_plus2 rig PLL_USB cannot hold its 1200 MHz VCO at that
    // voltage. It rails at ~975 MHz, clk_peri lands on ~40 MHz instead of 48, and
    // the console runs at 460800 * 40/48 = 384 kbaud. The table now floors the
    // band at 1200 mV, so this check guards the next such surprise rather than
    // that one.
    measured_clk_peri_khz = c.frequency_count_khz(c.CLOCKS_FC0_SRC_VALUE_CLK_PERI);
    measured_clk_sys_khz = c.frequency_count_khz(c.CLOCKS_FC0_SRC_VALUE_CLK_SYS);

    // Re-derive the reported clk_peri from the measurement when it is off, so the
    // baud programmed after this call matches the wire and the error message
    // reporting the problem is itself readable. The nominal value is kept while
    // the clock is merely imprecise (a locked PLL still measures a couple of
    // tenths of a percent off) so an accurate clock is never perturbed by
    // counter noise.
    if (khz_deviates(measured_clk_peri_khz, clk_peri_expected_khz)) {
        c.clock_set_reported_hz(c.clk_peri, measured_clk_peri_khz * 1000);
    }

    return 0;
}

/// What Step 4 above asks clk_peri to become, in kHz.
const clk_peri_expected_khz: u32 = 48_000;

/// Tolerance for "the clock is what we asked for", in tenths of a percent. A
/// locked PLL measures within ~0.3% of nominal; the failure this guards against
/// is ~17% out, so anything in between is comfortably decisive.
const clock_tolerance_permille: u32 = 20;

var measured_clk_peri_khz: u32 = 0;
var measured_clk_sys_khz: u32 = 0;

fn khz_deviates(measured: u32, expected: u32) bool {
    const slack = (expected * clock_tolerance_permille) / 1000;
    return measured < expected - slack or measured > expected + slack;
}

/// FC0 reading of clk_peri taken during apply_overclock(), in kHz.
export fn overclock_get_measured_clk_peri_khz() u32 {
    return measured_clk_peri_khz;
}

/// FC0 reading of clk_sys taken during apply_overclock(), in kHz.
export fn overclock_get_measured_clk_sys_khz() u32 {
    return measured_clk_sys_khz;
}

/// Non-zero when the measured clk_peri missed what Step 4 asked for, i.e. the
/// console baud had to be re-derived from the measurement.
export fn overclock_clk_peri_mismatch() u32 {
    return if (khz_deviates(measured_clk_peri_khz, clk_peri_expected_khz)) 1 else 0;
}

/// Non-zero when the measured clk_sys missed the configured CPU frequency.
export fn overclock_clk_sys_mismatch() u32 {
    return if (khz_deviates(measured_clk_sys_khz, pll_params.actual_freq_mhz * 1000)) 1 else 0;
}

export fn overclock_get_expected_clk_peri_khz() u32 {
    return clk_peri_expected_khz;
}

/// Read QMI M0 registers for debug dump
/// QMI base=0x400d0000, M[0] starts at offset 0x0c (after DIRECT_CSR/TX/RX)
export fn overclock_read_qmi_timing() u32 {
    const reg: *volatile u32 = @ptrFromInt(0x400d000c);
    return reg.*;
}
export fn overclock_read_qmi_rfmt() u32 {
    const reg: *volatile u32 = @ptrFromInt(0x400d0010);
    return reg.*;
}
export fn overclock_read_qmi_rcmd() u32 {
    const reg: *volatile u32 = @ptrFromInt(0x400d0014);
    return reg.*;
}
/// Read PLL_SYS CS register (bit 31 = LOCK)
export fn overclock_read_pll_sys_cs() u32 {
    const reg: *volatile u32 = @ptrFromInt(0x40050000);
    return reg.*;
}
/// Read PLL_SYS FBDIV
export fn overclock_read_pll_sys_fbdiv() u32 {
    const reg: *volatile u32 = @ptrFromInt(0x40050008);
    return reg.*;
}
/// Read PLL_SYS PRIM (postdividers)
export fn overclock_read_pll_sys_prim() u32 {
    const reg: *volatile u32 = @ptrFromInt(0x4005000c);
    return reg.*;
}
/// Read clk_sys selected
export fn overclock_read_clk_sys_selected() u32 {
    const base: *volatile u32 = @ptrFromInt(0x40010000 + 0x44);
    return base.*;
}
/// Read clk_ref selected
export fn overclock_read_clk_ref_selected() u32 {
    const base: *volatile u32 = @ptrFromInt(0x40010000 + 0x10);
    return base.*;
}
/// Read POWMAN VREG
export fn overclock_read_powman_vreg() u32 {
    const reg: *volatile u32 = @ptrFromInt(0x4010000c);
    return reg.*;
}

/// Exported getters so main.zig can log params without duplicating comptime logic
export fn overclock_get_target_khz() u32 {
    return comptime pll_params.actual_freq_mhz * 1000;
}

export fn overclock_get_vreg_code() u32 {
    return comptime requiredVregCode();
}

export fn overclock_get_vco_freq() u32 {
    return pll_params.vco_freq;
}

export fn overclock_get_postdiv1() u32 {
    return pll_params.postdiv1;
}

export fn overclock_get_postdiv2() u32 {
    return pll_params.postdiv2;
}

export fn overclock_is_enabled() u32 {
    return if (comptime clock_freq_mhz != 150) 1 else 0;
}

const QmiConfig = struct {
    timing: u32,
    rfmt: u32,
    rcmd: u32,
};

/// Compute optimal QMI M0 config for Quad I/O Fast Read (EBh).
/// W25Q128JV: tCLQV=8ns, tSHSL=50ns, tCSH=5ns
fn computeQmiConfig(target_khz: u32, flash_max_sck_mhz_val: u32) QmiConfig {
    const sys_mhz: u32 = (target_khz + 999) / 1000;

    // Read boot timing for cooldown/pagebreak fields
    // QMI base=0x400d0000, M[0].TIMING at offset 0x0c (after DIRECT_CSR/TX/RX)
    const qmi_m0_timing: *volatile u32 = @ptrFromInt(0x400d000c);
    const boot_timing = qmi_m0_timing.*;

    // CLKDIV: ceil(sys_mhz / flash_max_sck)
    var clkdiv: u32 = (sys_mhz + flash_max_sck_mhz_val - 1) / flash_max_sck_mhz_val;
    if (clkdiv < 1) clkdiv = 1;
    if (clkdiv > 255) clkdiv = 255;

    // RXDELAY: tCLQV=8ns, half-sysclk = 500/sys_mhz ns
    var rxdelay: u32 = (8 * sys_mhz + 499) / 500;
    if (rxdelay < 1) rxdelay = 1;
    if (rxdelay > 7) rxdelay = 7;
    if (rxdelay >= clkdiv) rxdelay = clkdiv - 1;

    // MIN_DESELECT: how long CS stays high before the QMI may reassert it, in
    // system clocks on top of the half SCK period it inserts anyway. Every XIP
    // miss that cannot continue a burst waits it out, so the figure to hold is
    // the part's deselect time for READS -- W25Q128JV tSHSL1 = 10 ns -- and not
    // the 50 ns tSHSL2 that governs erase, program and write-status. The XIP
    // window only reads; the one path that writes (status-register programming
    // in qmi_reinitialize_flash) runs in direct mode at CLKDIV=30, where the
    // gaps are two orders of magnitude larger than either figure.
    //
    // 50 ns was 27 cycles at 532 MHz against 12 ns's 7, out of a miss that
    // costs ~146 (external_memory.zig logs the measurement at boot).
    var min_desel: u32 = (flash_deselect_ns * sys_mhz + 999) / 1000;
    if (min_desel < 1) min_desel = 1;
    if (min_desel > 31) min_desel = 31;

    // SELECT_HOLD: tCSH=5ns
    var sel_hold: u32 = (5 * sys_mhz + 999) / 1000;
    if (sel_hold > 3) sel_hold = 3;

    const sel_setup: u32 = if (sys_mhz >= 200) 1 else 0;

    const cooldown: u32 = (boot_timing >> 30) & 0x3;
    var new_cooldown: u32 = (cooldown * sys_mhz + 149) / 150;
    if (new_cooldown > 3) new_cooldown = 3;
    if (new_cooldown < 1) new_cooldown = 1;

    const pagebreak: u32 = (boot_timing >> 28) & 0x3;

    const timing: u32 = (clkdiv << 0) |
        (rxdelay << 8) |
        (min_desel << 12) |
        (0 << 17) |
        (sel_hold << 23) |
        (sel_setup << 25) |
        (pagebreak << 28) |
        (new_cooldown << 30);

    // Quad I/O Fast Read (EBh):
    //   Prefix:  single, 8-bit (0xEB)
    //   Address: quad, 24 bits
    //   Suffix:  quad, 8-bit mode byte (0xFF)
    //   Dummy:   quad, 16 bits (4 SCK clocks)
    //   Data:    quad
    const rfmt: u32 = (0 << 0) | // PREFIX_WIDTH: single
        (2 << 2) | // ADDR_WIDTH:   quad
        (2 << 4) | // SUFFIX_WIDTH: quad
        (2 << 6) | // DUMMY_WIDTH:  quad
        (2 << 8) | // DATA_WIDTH:   quad
        (1 << 12) | // PREFIX_LEN:   8-bit
        (2 << 14) | // SUFFIX_LEN:   8-bit
        (4 << 16) | // DUMMY_LEN:    16 bits
        (0 << 28); // DTR:          off

    const rcmd: u32 = (0xFF << 8) | 0xEB;

    return .{ .timing = timing, .rfmt = rfmt, .rcmd = rcmd };
}
