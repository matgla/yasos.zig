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

// Zig wrapper around the SDIO_RP2350 C driver by Rabbit Hole Computing.
// https://github.com/rabbitholecomputing/SDIO_RP2350
// The low-level PIO/DMA SDIO bus code lives in sdio_rp2350.c; this file
// provides the interface expected by the yasos.zig MMC subsystem.

const std = @import("std");

const hal = @import("hal_interface");
const picosdk = @import("../picosdk.zig").picosdk;

const log = std.log.scoped(.@"mmc/sdio");

const sdio = @cImport({
    @cInclude("sdio_rp2350.h");
});

pub const MmcSdio = struct {
    const crc_window_us: u64 = 30 * std.time.us_per_s;
    const crc_fallback_threshold: u8 = 2;
    const crc_log_burst_limit: u8 = 10;
    const response_timeout_window_us: u64 = 30 * std.time.us_per_s;
    const response_timeout_fallback_threshold: u8 = 3;
    const response_timeout_log_burst_limit: u8 = 10;

    const TimingProfile = enum(u8) {
        init_300khz,
        mmc_20mhz,
        mmc_10mhz,
        mmc_5mhz,
        standard_25mhz,
        standard_16mhz,
        standard_12mhz,
        highspeed_50mhz,
        highspeed_33mhz,
    };

    _config: hal.mmc.MmcConfig,
    _initialized: bool,
    _timing_profile: TimingProfile,
    _crc_window_start_us: u64,
    _crc_failures_in_window: u8,
    _crc_logs_in_window: u8,
    _suppressed_crc_logs: u8,
    _response_timeout_window_start_us: u64,
    _response_timeouts_in_window: u8,
    _response_timeout_logs_in_window: u8,
    _suppressed_response_timeout_logs: u8,

    pub fn create(comptime config: hal.mmc.MmcConfig) MmcSdio {
        return .{
            ._config = config,
            ._initialized = false,
            ._timing_profile = .init_300khz,
            ._crc_window_start_us = 0,
            ._crc_failures_in_window = 0,
            ._crc_logs_in_window = 0,
            ._suppressed_crc_logs = 0,
            ._response_timeout_window_start_us = 0,
            ._response_timeouts_in_window = 0,
            ._response_timeout_logs_in_window = 0,
            ._suppressed_response_timeout_logs = 0,
        };
    }

    pub fn init(self: *MmcSdio) !void {
        self.apply_timing_profile(.init_300khz);
        self._initialized = true;
        log.info("SDIO interface initialized (init speed)", .{});
    }

    pub fn get_config(self: MmcSdio) hal.mmc.MmcConfig {
        return self._config;
    }

    // -- SDIO command interface --

    fn check_status(status: sdio.sdio_status_t) !void {
        switch (status) {
            sdio.SDIO_OK => return,
            sdio.SDIO_ERR_RESPONSE_TIMEOUT => return error.ResponseTimeout,
            sdio.SDIO_ERR_RESPONSE_CRC => return error.ResponseCrc,
            sdio.SDIO_ERR_RESPONSE_CODE => return error.ResponseCode,
            sdio.SDIO_ERR_DATA_TIMEOUT => return error.DataTimeout,
            sdio.SDIO_ERR_DATA_CRC => return error.DataCrc,
            sdio.SDIO_ERR_WRITE_CRC => return error.WriteCrc,
            sdio.SDIO_ERR_WRITE_FAIL => return error.WriteFail,
            sdio.SDIO_ERR_STOP_TIMEOUT => return error.StopTimeout,
            sdio.SDIO_ERR_INVALID_PARAM => return error.InvalidParam,
            else => return error.Unknown,
        }
    }

    fn now_us() u64 {
        return @intCast(picosdk.time_us_64());
    }

    fn reset_crc_window(self: *MmcSdio, now_us_value: u64) void {
        self._crc_window_start_us = now_us_value;
        self._crc_failures_in_window = 0;
        self._crc_logs_in_window = 0;
        self._suppressed_crc_logs = 0;
    }

    fn rotate_crc_window_if_needed(self: *MmcSdio, now_us_value: u64) void {
        if (self._crc_window_start_us == 0 or now_us_value - self._crc_window_start_us >= crc_window_us) {
            self.reset_crc_window(now_us_value);
        }
    }

    fn reset_response_timeout_window(self: *MmcSdio, now_us_value: u64) void {
        self._response_timeout_window_start_us = now_us_value;
        self._response_timeouts_in_window = 0;
        self._response_timeout_logs_in_window = 0;
        self._suppressed_response_timeout_logs = 0;
    }

    fn rotate_response_timeout_window_if_needed(self: *MmcSdio, now_us_value: u64) void {
        if (self._response_timeout_window_start_us == 0 or now_us_value - self._response_timeout_window_start_us >= response_timeout_window_us) {
            self.reset_response_timeout_window(now_us_value);
        }
    }

    fn scaled_divider(divider: c_int, numerator: c_int, denominator: c_int) c_int {
        return @intCast(@divTrunc(@as(i64, divider) * numerator + denominator - 1, denominator));
    }

    fn apply_timing_profile(self: *MmcSdio, profile: TimingProfile) void {
        var timing = switch (profile) {
            .init_300khz => sdio.rp2350_sdio_get_timing(sdio.SDIO_INITIALIZE),
            .mmc_20mhz, .mmc_10mhz, .mmc_5mhz => sdio.rp2350_sdio_get_timing(sdio.SDIO_MMC),
            .standard_25mhz, .standard_16mhz, .standard_12mhz => sdio.rp2350_sdio_get_timing(sdio.SDIO_STANDARD),
            .highspeed_50mhz, .highspeed_33mhz => sdio.rp2350_sdio_get_timing(sdio.SDIO_HIGHSPEED),
        };

        switch (profile) {
            .init_300khz, .mmc_20mhz, .standard_25mhz, .highspeed_50mhz => {},
            .mmc_10mhz => {
                timing.cmd_clk_divider *= 2;
                timing.data_clk_divider *= 2;
            },
            .mmc_5mhz => {
                timing.cmd_clk_divider *= 4;
                timing.data_clk_divider *= 4;
            },
            .standard_16mhz => {
                timing.cmd_clk_divider = scaled_divider(timing.cmd_clk_divider, 3, 2);
                timing.data_clk_divider = scaled_divider(timing.data_clk_divider, 3, 2);
            },
            .standard_12mhz => {
                timing.cmd_clk_divider *= 2;
                timing.data_clk_divider *= 2;
            },
            .highspeed_33mhz => {
                timing.cmd_clk_divider = scaled_divider(timing.cmd_clk_divider, 3, 2);
                timing.data_clk_divider = scaled_divider(timing.data_clk_divider, 3, 2);
            },
        }

        sdio.rp2350_sdio_init(timing);
        sdio.sdio_busy_wait_us_impl(10_000);
        self._timing_profile = profile;
    }

    fn timing_profile_label(profile: TimingProfile) []const u8 {
        return switch (profile) {
            .init_300khz => "300 kHz",
            .mmc_20mhz => "20 MHz",
            .mmc_10mhz => "10 MHz",
            .mmc_5mhz => "5 MHz",
            .standard_25mhz => "25 MHz",
            .standard_16mhz => "16 MHz",
            .standard_12mhz => "12.5 MHz",
            .highspeed_50mhz => "50 MHz",
            .highspeed_33mhz => "33 MHz",
        };
    }

    fn degrade_timing_profile(self: *MmcSdio) void {
        const next_profile = switch (self._timing_profile) {
            .highspeed_50mhz => .highspeed_33mhz,
            .highspeed_33mhz => .standard_25mhz,
            .standard_25mhz => .standard_16mhz,
            .standard_16mhz => .standard_12mhz,
            .standard_12mhz => .mmc_20mhz,
            .mmc_20mhz => TimingProfile.mmc_10mhz,
            .mmc_10mhz => .mmc_5mhz,
            .mmc_5mhz => .init_300khz,
            .init_300khz => .init_300khz,
        };

        if (next_profile == self._timing_profile) {
            log.err("SDIO recovery exhausted, already at lowest timing profile ({s})", .{timing_profile_label(self._timing_profile)});
            return;
        }

        self.apply_timing_profile(next_profile);
        log.info("SDIO recovery engaged, dropping timing profile to {s}", .{timing_profile_label(next_profile)});
    }

    fn report_rx_poll_failure(self: *MmcSdio, status: sdio.sdio_status_t, blocks_complete: u32, num_blocks: u32, bounce: bool) void {
        if (status != sdio.SDIO_ERR_DATA_CRC) {
            return;
        }

        const now_us_value = now_us();
        self.rotate_crc_window_if_needed(now_us_value);
        self._crc_failures_in_window +|= 1;

        if (self._crc_logs_in_window < crc_log_burst_limit) {
            if (bounce) {
                log.err("rx_poll (bounce) failed: {d}", .{status});
            } else {
                log.err("rx_poll failed: {d} ({d}/{d} blocks)", .{ status, blocks_complete, num_blocks });
            }
            self._crc_logs_in_window += 1;
        } else {
            self._suppressed_crc_logs +|= 1;
        }

        if (self._crc_failures_in_window >= crc_fallback_threshold) {
            if (self._suppressed_crc_logs > 0) {
                log.warn(
                    "Suppressed {d} additional SDIO RX CRC errors in the last {d}s",
                    .{ self._suppressed_crc_logs, crc_window_us / std.time.us_per_s },
                );
            }
            self.degrade_timing_profile();
            self.reset_crc_window(now_us_value);
        }
    }

    fn report_command_failure(self: *MmcSdio, cmd: u6, status: sdio.sdio_status_t, data_phase: bool) void {
        if (status != sdio.SDIO_ERR_RESPONSE_TIMEOUT or (cmd != 13 and cmd != 17 and cmd != 18 and cmd != 24)) {
            return;
        }

        const now_us_value = now_us();
        self.rotate_response_timeout_window_if_needed(now_us_value);
        self._response_timeouts_in_window +|= 1;

        if (self._response_timeout_logs_in_window < response_timeout_log_burst_limit) {
            if (data_phase) {
                log.err("CMD{d} data response failed: {d}", .{ cmd, status });
            } else {
                log.err("CMD{d} failed: {d}", .{ cmd, status });
            }
            self._response_timeout_logs_in_window += 1;
        } else {
            self._suppressed_response_timeout_logs +|= 1;
        }

        if (self._response_timeouts_in_window >= response_timeout_fallback_threshold) {
            if (self._suppressed_response_timeout_logs > 0) {
                log.warn(
                    "Suppressed {d} additional SDIO response timeouts in the last {d}s",
                    .{ self._suppressed_response_timeout_logs, response_timeout_window_us / std.time.us_per_s },
                );
            }
            self.degrade_timing_profile();
            self.reset_response_timeout_window(now_us_value);
        }
    }

    /// Determine per-command flags for the SDIO_RP2350 C driver.
    /// R3 responses (ACMD41, CMD58) carry no valid CRC or command index.
    /// Read commands (CMD17, CMD18) need STOP_CLK to halt the clock before
    /// switching to the data-reception PIO program.
    fn sdio_flags_for_cmd(cmd: u6) u32 {
        return switch (cmd) {
            41, 58 => sdio.SDIO_FLAG_NO_CRC | sdio.SDIO_FLAG_NO_CMD_TAG,
            17, 18 => sdio.SDIO_FLAG_STOP_CLK,
            else => 0,
        };
    }

    fn sdio_flags_for_data_cmd(cmd: u6) u32 {
        return switch (cmd) {
            6, 17, 18 => sdio.SDIO_FLAG_STOP_CLK,
            else => sdio_flags_for_cmd(cmd),
        };
    }

    pub fn send_sdio_command(self: *MmcSdio, cmd: u6, arg: u32) hal.mmc.SdioResponse {
        // CMD0, CMD4, CMD15 have no response
        if (cmd == 0 or cmd == 4 or cmd == 15) {
            const status = sdio.rp2350_sdio_command(@intCast(cmd), arg, null, 0, 0);
            if (status != sdio.SDIO_OK) {
                log.err("CMD{d} no-resp failed: {d}", .{ cmd, status });
            }
            return .{ .command_index = 0, .card_status = 0, .crc_ok = true };
        }

        var response: u32 = 0;
        const flags = sdio_flags_for_cmd(cmd);
        const status = sdio.rp2350_sdio_command_u32(@intCast(cmd), arg, &response, flags);
        if (status != sdio.SDIO_OK) {
            self.report_command_failure(cmd, status, false);
            return .{ .command_index = 0, .card_status = 0, .crc_ok = false };
        }

        return .{
            .command_index = cmd, // C driver validates cmd tag; on SDIO_OK it matched
            .card_status = response,
            .crc_ok = true,
        };
    }

    pub fn send_sdio_data_command(self: *MmcSdio, cmd: u6, arg: u32) hal.mmc.SdioResponse {
        var response: u32 = 0;
        const flags = sdio_flags_for_data_cmd(cmd);
        const status = sdio.rp2350_sdio_command_u32(@intCast(cmd), arg, &response, flags);
        if (status != sdio.SDIO_OK) {
            self.report_command_failure(cmd, status, true);
            return .{ .command_index = 0, .card_status = 0, .crc_ok = false };
        }

        return .{
            .command_index = cmd,
            .card_status = response,
            .crc_ok = true,
        };
    }

    pub fn send_sdio_command_long(self: *MmcSdio, cmd: u6, arg: u32) hal.mmc.SdioLongResponse {
        _ = self;
        var response: [16]u8 = [_]u8{0} ** 16;
        const flags: u32 = sdio.SDIO_FLAG_NO_CRC | sdio.SDIO_FLAG_NO_CMD_TAG;
        const status = sdio.rp2350_sdio_command(
            @intCast(cmd),
            arg,
            &response,
            16,
            flags,
        );
        if (status != sdio.SDIO_OK) {
            log.err("CMD{d} long response failed: {d}", .{ cmd, status });
            return .{ .data = [_]u8{0} ** 16, .valid = false };
        }
        return .{
            .data = response,
            .valid = true,
        };
    }

    // Aligned bounce buffer for DMA transfers when caller's buffer isn't 4-byte aligned.
    // Max 128 blocks per request = 64KB.
    var aligned_buf: [512]u8 align(4) = undefined;

    pub fn read_sdio_data(self: *MmcSdio, buf: []u8) anyerror!void {
        const block_size: usize = 512;
        const num_blocks: u32 = @intCast(buf.len / block_size);
        if (num_blocks == 0) return error.InvalidParam;

        // DMA requires 4-byte aligned buffer
        const is_aligned = (@intFromPtr(buf.ptr) & 3) == 0;
        const dma_buf = if (is_aligned) buf.ptr else &aligned_buf;
        const dma_blocks: u32 = if (is_aligned) num_blocks else 1;

        if (is_aligned) {
            // Fast path: direct DMA into caller's buffer
            const status = sdio.rp2350_sdio_rx_start(dma_buf, dma_blocks, 512);
            try check_status(status);
            var blocks_complete: u32 = 0;
            while (true) {
                const poll_status = sdio.rp2350_sdio_rx_poll(&blocks_complete);
                if (poll_status == sdio.SDIO_OK) {
                    _ = sdio.rp2350_sdio_stop();
                    return;
                }
                if (poll_status != sdio.SDIO_BUSY) {
                    self.report_rx_poll_failure(poll_status, blocks_complete, num_blocks, false);
                    // rx_poll already calls rp2350_sdio_stop() on error
                    try check_status(poll_status);
                }
            }
        } else {
            // Slow path: bounce buffer, one block at a time
            var i: u32 = 0;
            while (i < num_blocks) : (i += 1) {
                const status = sdio.rp2350_sdio_rx_start(dma_buf, 1, 512);
                try check_status(status);
                var blocks_complete: u32 = 0;
                while (true) {
                    const poll_status = sdio.rp2350_sdio_rx_poll(&blocks_complete);
                    if (poll_status == sdio.SDIO_OK) {
                        _ = sdio.rp2350_sdio_stop();
                        break;
                    }
                    if (poll_status != sdio.SDIO_BUSY) {
                        self.report_rx_poll_failure(poll_status, blocks_complete, 1, true);
                        // rx_poll already calls rp2350_sdio_stop() on error
                        try check_status(poll_status);
                    }
                }
                @memcpy(buf[512 * i .. 512 * (i + 1)], &aligned_buf);
            }
        }
    }

    pub fn write_sdio_data(self: *MmcSdio, buf: []const u8) anyerror!void {
        _ = self;
        const tx_block_size: usize = 512;
        const num_blocks: u32 = @intCast(buf.len / tx_block_size);
        if (num_blocks == 0) return error.InvalidParam;

        // DMA requires 4-byte aligned buffer
        const is_aligned = (@intFromPtr(buf.ptr) & 3) == 0;

        if (is_aligned) {
            const status = sdio.rp2350_sdio_tx_start(buf.ptr, num_blocks, 512);
            try check_status(status);
        } else {
            // Bounce: copy one block at a time
            // For multi-block unaligned writes we'd need a bigger bounce buffer;
            // for now handle the common single-block case
            if (num_blocks != 1) {
                log.err("unaligned multi-block write not supported", .{});
                return error.WriteFail;
            }
            @memcpy(&aligned_buf, buf[0..512]);
            const status = sdio.rp2350_sdio_tx_start(&aligned_buf, 1, 512);
            try check_status(status);
        }

        // Poll until transfer completes
        var blocks_complete: u32 = 0;
        while (true) {
            const poll_status = sdio.rp2350_sdio_tx_poll(&blocks_complete);
            if (poll_status == sdio.SDIO_OK) {
                _ = sdio.rp2350_sdio_stop();
                return;
            }
            if (poll_status != sdio.SDIO_BUSY) {
                log.err("tx_poll failed: {d} ({d}/{d} blocks)", .{ poll_status, blocks_complete, num_blocks });
                _ = sdio.rp2350_sdio_stop();
                try check_status(poll_status);
            }
        }
    }

    // -- SPI-compatible interface methods (for mmc.zig union compatibility) --

    pub fn build_command(self: MmcSdio, command: u6, argument: u32) [6]u8 {
        _ = self;
        const argument_value: u32 = std.mem.nativeToBig(u32, argument);
        var buffer: [6]u8 = [_]u8{0x00} ** 6;
        buffer[0] = 0x40 | @as(u8, command);
        const argument_bytes = std.mem.toBytes(argument_value);
        @memcpy(buffer[1..5], argument_bytes[0..4]);
        buffer[5] = @as(u8, std.hash.crc.Crc7Mmc.hash(buffer[0..5])) << 1 | 1;
        return buffer;
    }

    pub fn transmit_blocking(self: *MmcSdio, src: []const u8, dest: ?[]u8) void {
        _ = self;
        _ = src;
        _ = dest;
    }

    pub fn receive_blocking(self: *MmcSdio, dest: []u8) void {
        _ = self;
        _ = dest;
    }

    pub fn chip_select(self: MmcSdio, select: bool) void {
        _ = self;
        _ = select;
    }

    pub fn change_speed_to(self: *MmcSdio, speed_hz: u32) void {
        if (speed_hz <= 400_000) {
            self.apply_timing_profile(.init_300khz);
        } else if (speed_hz <= 25_000_000) {
            if (speed_hz <= 10_000_000) {
                self.apply_timing_profile(.mmc_10mhz);
            } else if (speed_hz <= 12_500_000) {
                self.apply_timing_profile(.standard_12mhz);
            } else if (speed_hz <= 16_000_000) {
                self.apply_timing_profile(.standard_16mhz);
            } else if (speed_hz <= 20_000_000) {
                self.apply_timing_profile(.mmc_20mhz);
            } else {
                self.apply_timing_profile(.standard_25mhz);
            }
        } else {
            if (speed_hz <= 33_000_000) {
                self.apply_timing_profile(.highspeed_33mhz);
            } else {
                self.apply_timing_profile(.highspeed_50mhz);
            }
        }
        log.info("SDIO speed changed to profile {s}", .{timing_profile_label(self._timing_profile)});
    }

    pub fn is_busy(self: MmcSdio) bool {
        _ = self;
        return false;
    }

    pub fn set_wide_bus(self: *MmcSdio, wide: bool) void {
        _ = self;
        _ = wide;
        // The C driver always operates in 4-bit mode
    }
};
