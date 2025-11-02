// Copyright (c) 2025 Mateusz Stadnik
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

const std = @import("std");

const hal = @import("hal_interface");

const log = std.log.scoped(.@"mmc/spi");

const mmc_spi = @cImport({
    @cInclude("mmc_spi.pio.h");
    @cInclude("hardware/clocks.h");
    @cInclude("hardware/pio.h");
    @cInclude("hardware/gpio.h");
});

pub const MmcSpi = struct {
    _config: hal.mmc.MmcConfig,
    _miso: u32,
    _mosi: u32,
    _sclk: u32,
    _cs: u32,
    _sm: u32,
    _pio: mmc_spi.PIO,

    pub fn create(comptime config: hal.mmc.MmcConfig) MmcSpi {
        return .{
            ._config = config,
            ._mosi = config.pins.cmd,
            ._miso = config.pins.d0,
            ._sclk = config.pins.clk,
            ._cs = config.pins.d0 + 3,
            ._sm = 0,
            ._pio = mmc_spi.pio0,
        };
    }

    pub fn build_command(self: MmcSpi, command: u6, argument: u32) [6]u8 {
        _ = self;
        const argument_value: u32 = std.mem.nativeToBig(u32, argument);
        var buffer: [6]u8 = [_]u8{0x00} ** 6;
        buffer[0] = 0x40 | @as(u8, command);
        const argument_bytes = std.mem.toBytes(argument_value);
        @memcpy(buffer[1..5], argument_bytes[0..4]);
        buffer[5] = @as(u8, std.hash.crc.Crc7Mmc.hash(buffer[0..5])) << 1 | 1;
        return buffer;
    }

    pub fn init(self: *MmcSpi) !void {
        self.init_cs();
        self.chip_select(false);
        try self.initialize_interface();
        self.enter_native_mode();
    }

    fn init_cs(self: MmcSpi) void {
        mmc_spi.gpio_init(self._cs);
        mmc_spi.gpio_put(self._cs, true);
        mmc_spi.gpio_set_dir(self._cs, mmc_spi.GPIO_OUT != 0);
    }

    fn enter_native_mode(self: *MmcSpi) void {
        const init_cmd: [10]u8 = [_]u8{0xff} ** 10;

        self.transmit_blocking(init_cmd[0..], null);
    }

    pub fn chip_select(self: MmcSpi, select: bool) void {
        mmc_spi.gpio_put(self._cs, !select);
    }

    pub fn transmit_blocking(self: MmcSpi, src: []const u8, dest: ?[]u8) void {
        const pio: *volatile mmc_spi.pio_h_t = @ptrCast(self._pio);
        const txfifo: *volatile mmc_spi.io_rw_8 = @ptrCast(&pio.txf[self._sm]);
        const rxfifo: *volatile mmc_spi.io_rw_8 = @ptrCast(&pio.rxf[self._sm]);

        var tx_remain: u32 = src.len;
        var rx_remain: u32 = src.len;
        var rx_index: u32 = 0;

        while (tx_remain != 0 or rx_remain != 0) {
            if (tx_remain != 0 and !mmc_spi.pio_sm_is_tx_fifo_full(self._pio, self._sm)) {
                txfifo.* = src[src.len - tx_remain];
                tx_remain -= 1;
            }

            if (rx_remain != 0 and !mmc_spi.pio_sm_is_rx_fifo_empty(self._pio, self._sm)) {
                if (dest) |d| {
                    if (rx_index < d.len) {
                        d[rx_index] = @intCast(rxfifo.*);
                        rx_index += 1;
                    } else {
                        _ = rxfifo.*;
                    }
                } else {
                    _ = rxfifo.*;
                }
                rx_remain -= 1;
            }
        }
        mmc_spi.gpio_put(self._sclk, false);
    }

    pub fn receive_blocking(self: MmcSpi, dest: []u8) void {
        const pio: *volatile mmc_spi.pio_hw_t = @ptrCast(self._pio);
        const txfifo: *volatile mmc_spi.io_rw_8 = @ptrCast(&pio.txf[self._sm]);
        const rxfifo: *volatile mmc_spi.io_rw_8 = @ptrCast(&pio.rxf[self._sm]);

        var tx_remain: u32 = dest.len;
        var rx_remain: u32 = dest.len;
        var rx_index: u32 = 0;

        while (tx_remain != 0 or rx_remain != 0) {
            if (tx_remain != 0 and !mmc_spi.pio_sm_is_tx_fifo_full(self._pio, self._sm)) {
                txfifo.* = 0xff;
                tx_remain -= 1;
            }

            if (rx_remain != 0 and !mmc_spi.pio_sm_is_rx_fifo_empty(self._pio, self._sm)) {
                if (rx_index < dest.len) {
                    dest[rx_index] = @intCast(rxfifo.*);
                    rx_index += 1;
                } else {
                    _ = rxfifo.*;
                }
                rx_remain -= 1;
            }
        }
        mmc_spi.gpio_put(self._sclk, false);
    }

    pub fn transmit_dma() isize {
        return 0;
    }

    fn initialize_interface(self: *MmcSpi) error{PIOInitializationFailure}!void {
        log.info("initializing interface", .{});
        var offset: u32 = 0;
        if (!mmc_spi.pio_claim_free_sm_and_add_program_for_gpio_range(&mmc_spi.mmc_spi_transmit_program, &self._pio, &self._sm, &offset, self._sclk, 6, true)) {
            return error.PIOInitializationFailure;
        }
        mmc_spi.pio_mmc_spi_transmit_init(self._pio, self._sm, offset, 60.0, self._sclk, self._mosi, self._miso);
    }

    pub fn change_speed_to(self: MmcSpi, speed_hz: u32) void {
        const frequency = mmc_spi.clock_get_hz(mmc_spi.clk_sys);
        var bus_frequency = speed_hz;
        if (speed_hz >= self._config.clock_speed) {
            bus_frequency = self._config.clock_speed;
        }
        const divider = frequency / speed_hz / 2;
        mmc_spi.pio_sm_set_clkdiv_int_frac(self._pio, self._sm, @intCast(divider), 0);
    }

    pub fn is_busy(self: MmcSpi) bool {
        return !mmc_spi.gpio_get(self._miso);
    }
};
