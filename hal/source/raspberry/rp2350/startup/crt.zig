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

const c = @cImport({
    @cInclude("hardware/regs/resets.h");
    @cInclude("hardware/resets.h");
    @cInclude("pico/runtime_init.h");
    @cInclude("pico/time.h");
    @cInclude("hardware/vreg.h");
    @cInclude("hardware/clocks.h");
    @cInclude("hardware/pll.h");
    @cInclude("hardware/xosc.h");
    @cInclude("hardware/ticks.h");
    @cInclude("hardware/structs/qmi.h");
    @cInclude("hardware/regs/clocks.h");
    @cInclude("overclock.h");
});

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

// POWMAN VREG voltage codes for direct register writes (bypasses SDK 1.3V clamp).
// Based on MichaelBell's RP2350 overclocking data with ~10% safety margin.
fn requiredVregCode() u32 {
    if (clock_freq_mhz <= 250) return 0x0b0; // 1.10V
    if (clock_freq_mhz <= 300) return 0x0d0; // 1.20V
    if (clock_freq_mhz <= 324) return 0x0e0; // 1.25V
    if (clock_freq_mhz <= 348) return 0x0f0; // 1.30V
    if (clock_freq_mhz <= 370) return 0x100; // 1.35V
    if (clock_freq_mhz <= 384) return 0x110; // 1.40V
    if (clock_freq_mhz <= 424) return 0x120; // 1.50V
    if (clock_freq_mhz <= 452) return 0x130; // 1.60V
    if (clock_freq_mhz <= 480) return 0x150; // 1.70V
    if (clock_freq_mhz <= 512) return 0x160; // 1.80V
    return 0x170; // 1.90V
}

const flash_max_sck_mhz: u32 = flash_config.xip_max_frequency_hz / 1_000_000;

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
var ram_vector_table: [ram_vector_table_size]usize linksection(".ram_vector_table") = [_]usize{0} ** ram_vector_table_size;

extern var __vectors_start: usize;
extern var __vectors_end: usize;

fn initialize_ram_vector_table() void {
    const vectors_start: *usize = @ptrCast(&__vectors_start);
    const vectors_end: *usize = @ptrCast(&__vectors_end);
    _ = c.__builtin_memcpy(@ptrCast(&ram_vector_table), vectors_start, @intFromPtr(vectors_end) - @intFromPtr(vectors_start));
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
        48_000_000,
        48_000_000,
    );

    // Step 5: Update SDK's cached frequencies (matches test)
    c.clock_set_reported_hz(c.clk_sys, target_khz * 1000);

    return 0;
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

    // MIN_DESELECT: tSHSL=50ns
    var min_desel: u32 = (50 * sys_mhz + 999) / 1000;
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
