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

const microsecond_to_femtosecond: u64 = 1000000000;
const nanosecond_to_femtosecond: u64 = 1000000;
const second_to_femtosecond: u64 = 1000000000000000;

// move this into config
const psram_max_frequency: u64 = 109000000;
// 8us in datasheet
const psram_ce_max_low_pulse_width_us: u64 = 8;
const psram_ce_min_deselect_ns: u64 = 50;

const qpi_ce_max_low_pulse_width_us: u64 = 125000000; //;psram_ce_max_low_pulse_width_us * microsecond_to_femtosecond / 64;
const qpi_ce_min_deselect_ns: u64 = 50000000; //psram_ce_min_deselect_ns * nanosecond_to_femtosecond;

// const config = @import("config").external_memory;

fn qmi_configure_timings() void {
    const system_clock = c.clock_get_hz(c.clk_sys);
    const clock_divider: u8 = @intCast((system_clock + psram_max_frequency - 1) / psram_max_frequency);
    // delay is in femtoseconds
    // const femtoseconds_per_cycle = second_to_femtosecond / system_clock;
    const max_select: u32 = 0x10; //@intCast(qpi_ce_max_low_pulse_width_us / femtoseconds_per_cycle);
    const min_deselect: u32 = 0x7; ////@intCast((qpi_ce_min_deselect_ns + femtoseconds_per_cycle - 1) / femtoseconds_per_cycle);
    // const max_select: u32 = 0x10;
    // const min_deselect: u32 = 0x7;
    const cooldown: u32 = 1;
    const select_hold: u32 = 3;
    const rx_delay: u32 = 1;
    const page_break = c.QMI_M1_TIMING_PAGEBREAK_VALUE_1024;

    // if (system_clock > 266000000) rx_delay = 3;

    qmi.*.m[1].timing.write(.{
        .clkdiv = @intCast(clock_divider),
        .rxdelay = @intCast(rx_delay),
        ._reserved0 = 0,
        .min_deselect = @intCast(min_deselect),
        .max_select = @intCast(max_select),
        .select_hold = select_hold,
        .select_setup = 0,
        ._reserved1 = 0,
        .pagebreak = page_break,
        .cooldown = cooldown,
    });
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
                log.err("Memory failure: memory mismatch at: {d}, expected: {d}, got: {d}", .{ i, index % 256, i.* });
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
            const addr: *volatile u32 = @ptrFromInt(0x15000000);
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
