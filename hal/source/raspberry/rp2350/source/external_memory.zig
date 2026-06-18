// original sequence from: https://github.com/FreddyVRetro/pico_psram/blob/main/psram.cpp
// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const c = @cImport({
    @cInclude("hardware/gpio.h");
    @cInclude("hardware/clocks.h");
    @cInclude("hardware/structs/xip.h");
    @cInclude("hardware/structs/qmi.h");
});

const config = @import("config");

const Mmio = @import("raspberry_common").mmio.Mmio;

pub const QmiM = extern struct {
    timing: Mmio(packed struct(u32) {
        clkdiv: u8,
        rxdelay: u3,
        _reserved0: u1,
        min_deselect: u5,
        max_select: u6,
        select_hold: u2,
        select_setup: u1,
        _reserved1: u2,
        pagebreak: u2,
        cooldown: u2,
    }),

    rfmt: Mmio(packed struct(u32) {
        prefix_width: u2,
        address_width: u2,
        suffix_width: u2,
        dummy_width: u2,
        data_width: u2,
        _reserved0: u2,
        prefix_len: u1,
        _reserved1: u1,
        suffix_len: u2,
        dummy_len: u3,
        _reserved2: u9,
        dtr: u1,
        _reserved3: u3,
    }),

    rcmd: Mmio(packed struct(u32) {
        prefix: u8,
        suffix: u8,
        _reserved: u16,
    }),

    wfmt: Mmio(packed struct(u32) {
        prefix_width: u2,
        address_width: u2,
        suffix_width: u2,
        dummy_width: u2,
        data_width: u2,
        _reserved0: u2,
        prefix_len: u1,
        _reserved1: u1,
        suffix_len: u2,
        dummy_len: u3,
        _reserved2: u9,
        dtr: u1,
        _reserved3: u3,
    }),

    wcmd: Mmio(packed struct(u32) {
        prefix: u8,
        suffix: u8,
        reserved: u16,
    }),
};

pub const Qmi = extern struct {
    direct_csr: Mmio(packed struct(u32) {
        en: u1, // 0
        busy: u1, // 1
        assert_cs0n: u1, // 2
        assert_cs1n: u1, // 3
        _reserved0: u2, // 4:5
        auto_cs0n: u1, // 6
        auto_cs1n: u1, // 7
        _reserved1: u2, // 8:9
        txfull: u1, // 10
        txempty: u1, // 11
        txlevel: u3, // 12:14
        _reserved2: u1, // 15
        rxempty: u1, // 16
        rxfull: u1, // 17
        rxlevel: u3, // 18:20
        _reserved3: u1, // 1
        clkdiv: u8, // 8
        rxdelay: u2, // 2
    }),
    direct_tx: Mmio(packed struct(u32) {
        data: u16,
        iwidth: u2,
        dwidth: u1,
        oe: u1,
        nopush: u1,
        _reserved: u11,
    }),
    direct_rx: Mmio(packed struct(u32) {
        data: u16,
        _reserved: u16,
    }),
    m: [2]QmiM,
};

const qmi: *volatile Qmi = @ptrFromInt(0x400d0000);

// Uncached, translated XIP window for chip-select 1 (PSRAM). Offset 0x1000000
// past XIP_NOCACHE_NOALLOC_BASE (0x14000000) skips the 16 MB CS0 (flash)
// aperture. Accesses here bypass the XIP cache, so reads exercise the real
// PSRAM read pipeline — essential for rxdelay calibration to be meaningful.
const psram_nocache_base: usize = 0x15000000;

const PsramCommands = struct {
    const QuadEnable: u32 = 0x35;
    const QuadEnd: u32 = 0xf5;
    const ReadId: u32 = 0x9f;
    const ResetEnable: u32 = 0x66;
    const Reset: u32 = 0x99;
    const QuadRead: u32 = 0xeb;
    const QuadWrite: u32 = 0x38;

    const KdgFail: u32 = 0x55;
    const KdgPass: u32 = 0x5d;
};

fn div_ceil_u64(numerator: u64, denominator: u64) u64 {
    return (numerator + denominator - 1) / denominator;
}

fn clamp_int(comptime T: type, value: u64) T {
    return @intCast(@min(value, std.math.maxInt(T)));
}

fn qmi_configure_timings() void {
    const system_clock: u64 = c.clock_get_hz(c.clk_sys);

    // M0 (flash) timing is managed by apply_overclock() in crt.zig — do not touch it here.

    const psram_clock_divider = clamp_int(u8, @max(2, div_ceil_u64(system_clock, config.psram.max_frequency_hz)));
    const psram_frequency = system_clock / psram_clock_divider;
    const psram_half_sck_ns = 500_000_000 / psram_frequency;
    const psram_extra_deselect_ns = if (config.psram.ce_min_deselect_ns > psram_half_sck_ns)
        config.psram.ce_min_deselect_ns - psram_half_sck_ns
    else
        0;
    const psram_extra_deselect_cycles = div_ceil_u64(psram_extra_deselect_ns * system_clock, 1_000_000_000);
    const psram_max_select_cycles = (config.psram.ce_max_low_us * system_clock) / (4 * 1_000_000);
    const psram_rx_delay: u3 = if (psram_frequency >= config.psram.rxdelay_hi_freq_threshold_hz)
        clamp_int(u3, config.psram.rxdelay_hi)
    else
        clamp_int(u3, config.psram.rxdelay_lo);

    // Add a half-SCK of CS-to-first-edge setup at high system clocks, matching
    // the flash (M0) path (which uses select_setup=1 for sys >= 200 MHz). At an
    // overclocked ~123 MHz PSRAM SCK the APS6404 needs that extra tCSS margin;
    // rxdelay calibration (run right after this) then re-centres around it.
    const psram_select_setup: u1 = if (system_clock >= 200_000_000) 1 else 0;

    qmi.*.m[1].timing.write(.{
        .clkdiv = psram_clock_divider,
        .rxdelay = psram_rx_delay,
        ._reserved0 = 0,
        .min_deselect = clamp_int(u5, psram_extra_deselect_cycles),
        .max_select = clamp_int(u6, psram_max_select_cycles / 64),
        .select_hold = 3,
        .select_setup = psram_select_setup,
        ._reserved1 = 0,
        // Force CE to deassert at every 1024-byte page (matches Pimoroni's
        // reference PSRAM driver). With NONE, a single CE-low QMI burst runs
        // linearly across APS6404L page boundaries toward the tCEM limit, which
        // caps the reliable SCK at ~84 MHz and produces intermittent single-bit
        // read corruption above that (see CONFIG_PSRAM_MAX_FREQUENCY_HZ note).
        // Breaking at the page boundary respects tCEM and resets the read
        // pipeline, allowing a higher SCK to be re-tried via rxdelay tuning.
        .pagebreak = c.QMI_M1_TIMING_PAGEBREAK_VALUE_1024,
        .cooldown = 1,
    });
}

// Maximum value of the 3-bit rxdelay field in QMI_M1_TIMING.
const psram_rxdelay_max: u8 = 7;

fn qmi_set_rxdelay(rxdelay: u3) void {
    // Read-modify-write so the rest of the calibrated timing word is preserved.
    qmi.*.m[1].timing.update(.{ .rxdelay = rxdelay });
    // Flush the QMI read pipeline so the next access samples with the new delay.
    qmi_dummy_read();
}

// Write a wrapping-LCG pattern over an uncached PSRAM region and read it back.
// Two complementary seeds toggle every data line in both directions, stressing
// the rxdelay sample point. Returns true only if every byte read back matches.
fn qmi_rxdelay_probe() bool {
    // 8 KiB crosses several 1024-byte page boundaries (the pagebreak unit) while
    // staying fast enough to sweep all eight delays during boot.
    const probe_len: u32 = 8 * 1024;
    const data = slicify(@as([*]volatile u8, @ptrFromInt(psram_nocache_base)), probe_len);
    const seeds = [_]u8{ 0xa5, 0x5a };
    for (seeds) |seed| {
        var v: u8 = seed;
        for (data) |*i| {
            i.* = v;
            v = v *% 31 +% 17;
        }
        v = seed;
        for (data) |*i| {
            const expected = v;
            v = v *% 31 +% 17;
            if (i.* != expected) {
                return false;
            }
        }
    }
    return true;
}

// Sweep every rxdelay value, find the widest contiguous window that reads back
// cleanly, and park rxdelay in the centre of that window for maximum setup/hold
// margin. This makes the PSRAM interface self-tune to whatever system clock the
// board is actually running at (e.g. 618 MHz overclock) instead of relying on a
// fixed frequency-threshold guess. Leaves the configured default untouched if
// nothing passes, so a failed sweep degrades to the previous behaviour.
fn qmi_calibrate_rxdelay() void {
    var best_start: i32 = -1;
    var best_len: u32 = 0;
    var run_start: i32 = -1;

    var d: u8 = 0;
    while (d <= psram_rxdelay_max) : (d += 1) {
        qmi_set_rxdelay(@intCast(d));
        const ok = qmi_rxdelay_probe();
        log.err("PSRAM rxdelay {d}: {s}", .{ d, if (ok) "pass" else "fail" });
        if (ok) {
            if (run_start < 0) run_start = @intCast(d);
            const run_len = d - @as(u8, @intCast(run_start)) + 1;
            if (run_len > best_len) {
                best_len = run_len;
                best_start = run_start;
            }
        } else {
            run_start = -1;
        }
    }

    if (best_len == 0) {
        log.err("PSRAM rxdelay calibration failed, keeping configured default", .{});
        // Restore the configured default that the sweep last overwrote.
        qmi_configure_timings();
        return;
    }

    const start: u32 = @intCast(best_start);
    const chosen: u3 = @intCast(start + (best_len - 1) / 2);
    log.err("PSRAM rxdelay calibrated: window [{d}..{d}], chosen {d}", .{ start, start + best_len - 1, chosen });
    qmi_set_rxdelay(chosen);
}

fn qmi_configure_commands() void {
    qmi.*.m[1].rfmt.write(.{
        .prefix_width = c.QMI_M1_RFMT_PREFIX_WIDTH_VALUE_Q,
        .address_width = c.QMI_M1_RFMT_ADDR_WIDTH_VALUE_Q,
        .suffix_width = c.QMI_M1_RFMT_SUFFIX_WIDTH_VALUE_Q,
        .dummy_width = c.QMI_M1_RFMT_DUMMY_WIDTH_VALUE_Q,
        .data_width = c.QMI_M1_RFMT_DATA_WIDTH_VALUE_Q,
        ._reserved0 = 0,
        .prefix_len = c.QMI_M1_RFMT_PREFIX_LEN_VALUE_8,
        ._reserved1 = 0,
        .suffix_len = c.QMI_M1_RFMT_SUFFIX_LEN_VALUE_NONE,
        .dummy_len = c.QMI_M1_RFMT_DUMMY_LEN_VALUE_24,
        ._reserved2 = 0,
        .dtr = 0,
        ._reserved3 = @intCast(0),
    });

    qmi.*.m[1].rcmd.write(.{
        .prefix = PsramCommands.QuadRead,
        .suffix = 0,
        ._reserved = 0,
    });

    qmi.*.m[1].wfmt.write(.{
        .prefix_width = c.QMI_M1_WFMT_PREFIX_WIDTH_VALUE_Q,
        .address_width = c.QMI_M1_WFMT_ADDR_WIDTH_VALUE_Q,
        .suffix_width = c.QMI_M1_WFMT_SUFFIX_WIDTH_VALUE_Q,
        .dummy_width = c.QMI_M1_WFMT_DUMMY_WIDTH_VALUE_Q,
        .data_width = c.QMI_M1_WFMT_DATA_WIDTH_VALUE_Q,
        ._reserved0 = 0,
        .prefix_len = c.QMI_M1_WFMT_PREFIX_LEN_VALUE_8,
        ._reserved1 = 0,
        .suffix_len = c.QMI_M1_WFMT_SUFFIX_LEN_VALUE_NONE,
        .dummy_len = c.QMI_M1_WFMT_DUMMY_LEN_VALUE_NONE,
        ._reserved2 = 0,
        .dtr = 0,
        ._reserved3 = 0,
    });

    qmi.*.m[1].wcmd.write(.{
        .prefix = PsramCommands.QuadWrite,
        .suffix = 0,
        .reserved = 0,
    });
}

pub fn qmi_determine_psram_size(data: u32) u32 {
    var psram_size: u32 = 0;
    const kgd = data >> 8;
    const eid = data & 0xFF;
    if (kgd == PsramCommands.KdgPass) {
        psram_size = 1024 * 1024;
        const size_id = eid >> 5;
        if (eid == 0x26 or size_id == 2) {
            psram_size *= 8;
        } else if (size_id == 0) {
            psram_size *= 2;
        } else if (size_id == 1) {
            psram_size *= 4;
        }
    }
    return psram_size;
}

pub fn qmi_delay(delay: u32) void {
    var d = delay;
    while (d > 0) {
        d -= 1;
        asm volatile ("nop");
    }
}

fn slicify(ptr: [*]volatile u8, len: usize) []volatile u8 {
    return ptr[0..len];
}

extern fn qmi_initialize_m1() usize;
extern fn qmi_dummy_read() void;
extern fn qmi_reinitialize_flash() void;
// RAM-resident flash (M0) rxdelay calibration in startup/overclock.c.
extern fn overclock_calibrate_flash_rxdelay(out_lo: *u32, out_hi: *u32) u32;
const log = std.log.scoped(.hal_external_memory);

pub const ExternalMemory = struct {
    _initialized: bool = false,
    _psram_size: u32 = 0,

    pub fn enable(self: *ExternalMemory) bool {
        if (!self._initialized) {
            return self.init();
        }
        return false;
    }

    pub fn disable() void {}

    fn print_qmi_directcsr(self: ExternalMemory) void {
        log.debug(" direct_csr", .{});
        _ = self;
        const state = qmi.*.direct_csr.read();
        log.debug("  en: {d}", .{state.en});
        log.debug("  busy: {d}", .{state.busy});
        log.debug("  assert_cs0n: {d}", .{state.assert_cs0n});
        log.debug("  assert_cs1n: {d}", .{state.assert_cs1n});
        log.debug("  auto_cs0n: {d}", .{state.auto_cs0n});
        log.debug("  auto_cs1n: {d}", .{state.auto_cs1n});
        log.debug("  txfull: {d}", .{state.txfull});
        log.debug("  txempty: {d}", .{state.txempty});
        log.debug("  txlevel: {d}", .{state.txlevel});
        log.debug("  rxempty: {d}", .{state.rxempty});
        log.debug("  rxfull: {d}", .{state.rxfull});
        log.debug("  rxlevel: {d}", .{state.rxlevel});
        log.debug("  clkdiv: {d}", .{state.clkdiv});
        log.debug("  rxdelay: {d}", .{state.rxdelay});
    }

    fn print_qmi_timings(self: ExternalMemory) void {
        _ = self;
        for (0..2) |i| {
            log.debug(" m[{d}] timing", .{i});
            const state = qmi.*.m[i].timing.read();
            log.debug("  clkdiv: {d}", .{state.clkdiv});
            log.debug("  rxdelay: {d}", .{state.rxdelay});
            log.debug("  min_deselect: {d}", .{state.min_deselect});
            log.debug("  max_select: {d}", .{state.max_select});
            log.debug("  select_hold: {d}", .{state.select_hold});
            log.debug("  select_setup: {d}", .{state.select_setup});
            log.debug("  pagebreak: {d}", .{state.pagebreak});
            log.debug("  cooldown: {d}", .{state.cooldown});

            const rfmt = qmi.*.m[i].rfmt.read();
            log.debug(" m[{d}] rfmt", .{i});
            log.debug("  prefix_width: {d}", .{rfmt.prefix_width});
            log.debug("  address_width: {d}", .{rfmt.address_width});
            log.debug("  suffix_width: {d}", .{rfmt.suffix_width});
            log.debug("  dummy_width: {d}", .{rfmt.dummy_width});
            log.debug("  data_width: {d}", .{rfmt.data_width});
            log.debug("  prefix_len: {d}", .{rfmt.prefix_len});
            log.debug("  suffix_len: {d}", .{rfmt.suffix_len});
            log.debug("  dummy_len: {d}", .{rfmt.dummy_len});
            log.debug("  dtr: {d}", .{rfmt.dtr});

            const rcmd = qmi.*.m[i].rcmd.read();
            log.debug(" m[{d}] rcmd", .{i});
            log.debug("  prefix: {x}", .{rcmd.prefix});
            log.debug("  suffix: {x}", .{rcmd.suffix});

            const wfmt = qmi.*.m[i].wfmt.read();
            log.debug(" m[{d}] wfmt", .{i});
            log.debug("  prefix_width: {d}", .{wfmt.prefix_width});
            log.debug("  address_width: {d}", .{wfmt.address_width});
            log.debug("  suffix_width: {d}", .{wfmt.suffix_width});
            log.debug("  dummy_width: {d}", .{wfmt.dummy_width});
            log.debug("  data_width: {d}", .{wfmt.data_width});
            log.debug("  prefix_len: {d}", .{wfmt.prefix_len});
            log.debug("  suffix_len: {d}", .{wfmt.suffix_len});
            log.debug("  dummy_len: {d}", .{wfmt.dummy_len});
            log.debug("  dtr: {d}", .{wfmt.dtr});

            const wcmd = qmi.*.m[i].wcmd.read();
            log.debug(" m[{d}] wcmd", .{i});
            log.debug("  prefix: {x}", .{wcmd.prefix});
            log.debug("  suffix: {x}", .{wcmd.suffix});
        }
    }

    pub fn dump_configuration(self: ExternalMemory) void {
        log.debug("----- QMI Configuration ------", .{});
        log.debug(" enabled: {any}", .{self._initialized});
        self.print_qmi_directcsr();
        self.print_qmi_timings();
        log.debug("------------------------------", .{});
    }

    pub fn get_memory_size(self: ExternalMemory) usize {
        return self._psram_size;
    }

    pub fn perform_post(self: *ExternalMemory) bool {
        var prng = std.Random.DefaultPrng.init(1000);

        const data = slicify(
            @as([*]volatile u8, @ptrFromInt(0x15000000)),
            self._psram_size,
        );

        var rand = prng.random();
        const start: u8 = rand.int(u8);
        var index: u32 = start;
        for (data) |*i| {
            i.* = @intCast(index % 256);
            index += 1;
        }
        index = start;
        for (data) |*i| {
            if (i.* != @as(u8, @intCast(index % 256))) {
                log.err("Memory failure: memory mismatch at: {d}, expected: {d}, got: {d}", .{ @intFromPtr(i), index % 256, i.* });
                self._psram_size = 0;
                self._initialized = false;
                return false;
            }
            index += 1;
        }
        return true;
    }

    fn init(self: *ExternalMemory) bool {
        c.gpio_set_function(config.psram.cs_pin, c.GPIO_FUNC_XIP_CS1);
        qmi_reinitialize_flash();
        const init_code = qmi_initialize_m1();
        if (init_code > 0) {
            self._initialized = true;
            self._psram_size = qmi_determine_psram_size(init_code);
            qmi_configure_commands();
            qmi_configure_timings();
            qmi_dummy_read();
            // Auto-tune the read sample point for the current system clock; the
            // fixed rxdelay from qmi_configure_timings() only holds at stock
            // speeds and corrupts reads once the core is overclocked.
            qmi_calibrate_rxdelay();

            // Calibrate the flash (M0) rxdelay the same way. Flash and PSRAM
            // share the QMI bus, so a mis-sampled flash read can desync the read
            // pipeline for the very next PSRAM access; the boot formula in
            // computeQmiConfig() under-delays flash once overclocked. Runs from
            // RAM and flushes the XIP cache internally.
            var flash_rx_lo: u32 = 0;
            var flash_rx_hi: u32 = 0;
            const flash_rx = overclock_calibrate_flash_rxdelay(&flash_rx_lo, &flash_rx_hi);
            if (flash_rx_lo <= flash_rx_hi) {
                log.err("Flash rxdelay calibrated: window [{d}..{d}], chosen {d}", .{ flash_rx_lo, flash_rx_hi, flash_rx });
            } else {
                log.err("Flash rxdelay calibration inconclusive, keeping {d}", .{flash_rx});
            }
            const addr: *volatile u32 = @ptrFromInt(psram_nocache_base);
            addr.* = 0x12345678;
            if (addr.* != 0x12345678) {
                self._initialized = false;
                self._psram_size = 0;
            }
        } else {
            self._initialized = false;
        }
        return self._initialized;
    }
};
