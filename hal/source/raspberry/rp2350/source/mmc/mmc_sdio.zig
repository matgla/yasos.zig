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

const sdio = @import("mmc_sdio_headers");

pub const MmcSdio = struct {
    const crc_window_us: u64 = 30 * std.time.us_per_s;
    const crc_fallback_threshold: u8 = 5;
    const crc_log_burst_limit: u8 = 10;
    const response_timeout_window_us: u64 = 30 * std.time.us_per_s;
    const response_timeout_fallback_threshold: u8 = 5;
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
        var response: [16]u8 = @splat(0);
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
            return .{ .data = @splat(0), .valid = false };
        }
        return .{
            .data = response,
            .valid = true,
        };
    }

    // Aligned bounce buffer for DMA transfers whose caller buffer cannot be
    // DMA'd in place (see `direct` below).
    //
    // Its size is what decides how many 512-byte blocks go out per DMA setup,
    // and that is the single biggest term in the transfer cost. The C driver
    // chains two DMA channels so a whole multi-block burst streams with no CPU
    // in the loop (sdio_rp2350.c rp2350_sdio_rx_start); handing it one block at
    // a time, as this did, throws that away and pays a PIO re-arm, a poll and a
    // copy for every sector.
    //
    // Measured against the 48.36 MHz bus: the wire needs 21.5 us per sector,
    // the copy into PSRAM costs ~9.3 us at the 55 MB/s this board's PSRAM
    // clears at, and the per-DMA-setup remainder was ~25 us. Amortising that
    // over N blocks gives 55.8 us/sector at N=1, 33.9 at N=8 and 32.4 at N=16
    // -- so 8 blocks takes ~85% of what is available and 16 would cost twice
    // the RAM for another 5%. kernel_ram is 76 KB shared between .bss and the
    // kernel heap, which is not somewhere to spend 8 KB for that.
    //
    // 16 was tried on hardware and measured *worse* (write 4385 -> 4276 KiB/s,
    // i.e. nothing outside noise) for 4 KB more .bss, so the reasoning above
    // still holds on the write side. It also settled a question about where
    // write time goes: the ~65 us/block that the transfer buckets do not
    // account for is not per-chunk, because doubling the chunk did not move it.
    // Nor is it per-request -- reformatting the volume from 8 KiB to 64 KiB
    // clusters, which cuts a 32 KiB write from four requests to one, changed
    // nothing either. It is per-block, and where exactly is still unknown.
    const bounce_blocks: u32 = 8;
    var aligned_buf: [bounce_blocks * 512]u8 align(4) = undefined;

    // The C driver's hard ceiling per request (SDIO_MAX_BLOCKS_PER_REQ); its
    // DMA descriptor and checksum arrays are sized for it.
    const max_blocks_per_req: u32 = 128;

    // Cap on how many blocks go out under one `cpsid i`. Reads have always
    // masked the whole transfer; writes deliberately did not, because a
    // multi-block write under a single mask outlasts the 32-byte console UART
    // FIFO and the target starts dropping host bytes. Chunking at 8 keeps that
    // window in the same order as the one-block-per-section policy it replaces
    // while still filling the DMA.
    const tx_blocks_per_section: u32 = bounce_blocks;

    // Start of SRAM. Below this are the XIP windows (flash at 0x10000000,
    // PSRAM at 0x11000000), whose contents reach the DMA through the QMI
    // without passing the XIP cache — see write_sdio_data.
    const sram_base: usize = 0x20000000;

    // Disable all interrupts during DMA poll loops to prevent:
    // 1. Context switches (PendSV/SysTick preemption)
    // 2. DMA IRQ reentrancy — the hardware ISR calling rp2350_sdio_dma_irq()
    //    while rx_poll() is already inside it causes blocks_checksumed to be
    //    overwritten with a stale value, re-verifying a block whose received
    //    checksum was already cleared to 0xDEADBEEF → false CRC error.
    // DMA transfers continue autonomously via hardware control-block chaining;
    // no IRQ is needed for the transfer to proceed.
    inline fn disable_irq() void {
        asm volatile ("cpsid i" ::: .{ .memory = true });
    }

    inline fn enable_irq() void {
        asm volatile ("cpsie i" ::: .{ .memory = true });
    }

    /// Sink for the C driver's SDIO_ERRMSG. Everything sdio_rp2350.c reports --
    /// command timeouts, CRC errors, PIO program problems -- was being thrown
    /// away, because the macro defaults to nothing and nothing ever defined it.
    /// Hours of this investigation would have been minutes with it wired up.
    export fn yasos_sdio_errmsg(txt: [*:0]const u8, arg1: u32, arg2: u32) void {
        log.err("{s} ({d}, 0x{x})", .{ txt, arg1, arg2 });
    }

    pub fn read_sdio_data(self: *MmcSdio, buf: []u8) anyerror!void {
        // For sub-block reads (e.g. CMD6 switch status = 64 bytes), use
        // the buffer length as the block size so the PIO/DMA reads exactly
        // the right number of bytes from the data lines.
        const block_size: usize = if (buf.len < 512) buf.len else 512;
        const num_blocks: u32 = @intCast(buf.len / block_size);
        if (num_blocks == 0) return error.InvalidParam;

        // DMA writes are not snooped by the XIP cache, so a destination in the
        // flash or PSRAM windows could leave sdio_verify_rx_checksums() reading
        // stale cached bytes and reporting a CRC error against data that
        // arrived intact. Only an SRAM destination is safe to land in directly;
        // everything else lands in the bounce and is copied out. This mirrors
        // write_sdio_data's `direct`, and it earns its keep here because the
        // FatFs cache lines sit on the kernel heap, i.e. in SRAM -- every
        // cached metadata read now skips the copy altogether.
        const direct = ((@intFromPtr(buf.ptr) & 3) == 0) and (@intFromPtr(buf.ptr) >= sram_base);
        const chunk_limit: u32 = if (direct)
            max_blocks_per_req
        else
            @intCast(@min(@as(usize, max_blocks_per_req), aligned_buf.len / block_size));

        // Between chunks of a multi-block CMD18 transfer we must NOT call
        // rp2350_sdio_stop() — that resets PIO state to SDIO_IDLE, causing
        // a full reinit on the next rx_start which disrupts the card's
        // continuous data stream.  Instead let rx_poll set SDIO_RX_DONE so
        // the next rx_start can continue seamlessly.
        disable_irq();
        var i: u32 = 0;
        while (i < num_blocks) {
            const chunk: u32 = @min(num_blocks - i, chunk_limit);
            const offset = block_size * i;
            const target: [*]u8 = if (direct) buf.ptr + offset else &aligned_buf;

            const status = sdio.rp2350_sdio_rx_start(target, chunk, @intCast(block_size));
            if (status != sdio.SDIO_OK) {
                enable_irq();
                try check_status(status);
            }
            var blocks_complete: u32 = 0;
            while (true) {
                const poll_status = sdio.rp2350_sdio_rx_poll(&blocks_complete);
                if (poll_status == sdio.SDIO_OK) {
                    // Don't call stop() here — leave state as SDIO_RX_DONE
                    // so the next rx_start continues the multi-block stream.
                    break;
                }
                if (poll_status != sdio.SDIO_BUSY) {
                    enable_irq();
                    self.report_rx_poll_failure(poll_status, blocks_complete, chunk, !direct);
                    try check_status(poll_status);
                }
            }
            if (!direct) {
                const span = block_size * chunk;
                @memcpy(buf[offset .. offset + span], aligned_buf[0..span]);
            }
            i += chunk;
        }
        _ = sdio.rp2350_sdio_stop();
        enable_irq();
    }

    pub fn write_sdio_data(self: *MmcSdio, buf: []const u8) anyerror!void {
        _ = self;
        const tx_block_size: usize = 512;
        const num_blocks: u32 = @intCast(buf.len / tx_block_size);
        if (num_blocks == 0) return error.InvalidParam;

        // DMA requires a 4-byte aligned source. The XIP cache is not snooped
        // on DMA *reads* either, and it is write-back for PSRAM
        // (XIP_CTRL.WRITABLE_M1). CPU stores into a PSRAM buffer can therefore
        // still be sitting dirty in the cache while DMA pulls the line
        // straight off the QMI, transferring stale bytes to the card. Only
        // SRAM is safe to DMA out of directly; anything in the XIP windows
        // goes through the SRAM bounce. This mirrors read_sdio_data, which
        // bounces for the same reason in the other direction.
        const direct = ((@intFromPtr(buf.ptr) & 3) == 0) and (@intFromPtr(buf.ptr) >= sram_base);
        const chunk_limit: u32 = if (direct)
            tx_blocks_per_section
        else
            @intCast(@min(@as(usize, tx_blocks_per_section), aligned_buf.len / tx_block_size));

        // A chunk per critical section rather than one around the whole
        // transfer. The stream survives the gap: between chunks the driver
        // parks in SDIO_TX_DONE, from which the next tx_start continues without
        // reinitializing the PIO, and the card sits waiting for the next start
        // token, so neither an interrupt nor a context switch in the gap can
        // disturb it. The gap is where everything a masked window starves gets
        // to run -- a whole multi-block write under one cpsid is milliseconds,
        // far longer than the 32-byte UART FIFO can cover, which is why the
        // chunk is bounded rather than simply set to the request length.
        var i: u32 = 0;
        while (i < num_blocks) {
            const chunk: u32 = @min(num_blocks - i, chunk_limit);
            const span = tx_block_size * chunk;
            const offset = tx_block_size * i;
            var src: [*]const u8 = buf.ptr + offset;
            if (!direct) {
                @memcpy(aligned_buf[0..span], buf[offset .. offset + span]);
                src = &aligned_buf;
            }

            disable_irq();
            const status = sdio.rp2350_sdio_tx_start(src, chunk, @intCast(tx_block_size));
            if (status != sdio.SDIO_OK) {
                _ = sdio.rp2350_sdio_stop();
                enable_irq();
                try check_status(status);
                return error.Unknown; // not reached: status was not SDIO_OK
            }

            var blocks_complete: u32 = 0;
            while (true) {
                const poll_status = sdio.rp2350_sdio_tx_poll(&blocks_complete);
                if (poll_status == sdio.SDIO_OK) {
                    break;
                }
                if (poll_status != sdio.SDIO_BUSY) {
                    enable_irq();
                    log.err("tx_poll failed: {d} (block {d}/{d})", .{ poll_status, i, num_blocks });
                    _ = sdio.rp2350_sdio_stop();
                    try check_status(poll_status);
                    return error.Unknown; // not reached: status was not SDIO_OK
                }
            }
            enable_irq();
            i += chunk;
        }

        // Back to the command state machine, which also restarts the
        // continuous clock the card needs in order to signal busy while it
        // programs what it buffered.
        disable_irq();
        _ = sdio.rp2350_sdio_stop();
        enable_irq();
    }

    // -- SPI-compatible interface methods (for mmc.zig union compatibility) --

    pub fn build_command(self: MmcSdio, command: u6, argument: u32) [6]u8 {
        _ = self;
        const argument_value: u32 = std.mem.nativeToBig(u32, argument);
        var buffer: [6]u8 = @splat(0x00);
        buffer[0] = 0x40 | @as(u8, command);
        const argument_bytes = std.mem.toBytes(argument_value);
        @memcpy(buffer[1..5], argument_bytes[0..4]);
        buffer[5] = @as(u8, std.hash.crc.@"CRC-7/MMC".hash(buffer[0..5])) << 1 | 1;
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
        return sdio.rp2350_sdio_is_card_busy();
    }

    pub fn set_wide_bus(self: *MmcSdio, wide: bool) void {
        _ = self;
        _ = wide;
        // The C driver always operates in 4-bit mode
    }
};
