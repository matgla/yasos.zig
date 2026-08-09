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

const kernel = @import("../../kernel.zig");

const arch = @import("arch");

const hal = @import("hal");

const log = std.log.scoped(.@"mmc/driver");

const card_parser = @import("card_parser.zig");

const CardType = enum(u2) {
    MMCv3,
    SDv1,
    SDv2Block,
    SDv2Byte,
};

const R1 = struct {
    r1: u8,

    pub fn init() R1 {
        return .{
            .r1 = 0,
        };
    }
};
const R3 = struct {
    r1: u8,
    ocr: u32,

    pub fn init() R3 {
        return .{
            .r1 = 0,
            .ocr = 0,
        };
    }
};
const R7 = R3;

const sd_switch_check: u32 = 0;
const sd_switch_set: u32 = 1;
const sd_switch_group_access: u32 = 0;
const sd_switch_access_default: u32 = 0;
const sd_switch_access_high_speed: u32 = 1;

pub const MmcIo = struct {
    const Self = @This();
    _mmc: *hal.mmc.Mmc,
    _card_type: ?CardType,
    _size: u64,
    _initialized: bool,
    // Kept past initialization because ACMD23 needs it on every multi-block
    // write: an application command is addressed by CMD55 + RCA.
    _rca: u16,

    pub fn create(mmc: *hal.mmc.Mmc) MmcIo {
        return .{
            ._mmc = mmc,
            ._card_type = null,
            ._size = 0,
            ._initialized = false,
            ._rca = 0,
        };
    }

    pub fn init(self: *Self) anyerror!void {
        const state = arch.sync.save_and_disable_interrupts();
        defer arch.sync.restore_interrupts(state);
        try self._mmc.init();
        const config = self._mmc.get_config();
        switch (config.mode) {
            .SPI => {
                self.initialize_spi_mmc() catch |err| {
                    log.info("initialization failed with an error: {s}", .{@errorName(err)});
                    return err;
                };
            },
            .SDIO => {
                self.initialize_sdio_mmc() catch |err| {
                    log.info("SDIO initialization failed with an error: {s}", .{@errorName(err)});
                    return err;
                };
            },
            else => {
                log.err("Unsupported mode in config", .{});
                return kernel.errno.ErrnoSet.NotImplemented;
            },
        }
    }

    pub fn deinit(self: *Self) void {
        log.info("Deleting MMC driver, waiting for card to reach idle state", .{});
        const buffer: [1]u8 = [_]u8{0xff};
        while (self._mmc.is_busy()) {
            self._mmc.transmit_blocking(buffer[0..], null);
        }
    }

    pub fn read(self: *const Self, address: u64, buf: []u8) isize {
        const state = arch.sync.save_and_disable_interrupts();
        defer arch.sync.restore_interrupts(state);
        if (address % 512 != 0) {
            log.err("Address must be aligned to 512 bytes, got: {d}", .{address});
            return -1;
        }

        if (buf.len % 512 != 0 or buf.len == 0) {
            log.err("Buffer must be aligned to 512 bytes, got: {d}", .{buf.len});
            return -1;
        }

        const config = self._mmc.get_config();
        if (config.mode == .SDIO) {
            return self.sdio_read(address, buf);
        }

        const block_address = address >> 9;
        const num_blocks = buf.len / 512;
        var i: usize = 0;
        var retransmissions: usize = 0;
        const max_retransmissions: usize = 3;
        while (i < num_blocks) {
            self.block_read_impl(17, @intCast(block_address + i), buf[512 * i .. 512 * (i + 1)]) catch |err| {
                log.warn("Reading block {d} failed with error: {s}, size: {d}", .{ i, @errorName(err), buf.len });
                if (retransmissions < max_retransmissions) {
                    retransmissions += 1;
                    continue;
                }
                log.err("Permanent read error on block {d}: {s}", .{ i, @errorName(err) });
                return -1;
            };
            i += 1;
        }

        return @intCast(buf.len);
    }

    pub fn write(self: *const Self, address: u64, buf: []const u8) isize {
        const state = arch.sync.save_and_disable_interrupts();
        defer arch.sync.restore_interrupts(state);
        if (address % 512 != 0) {
            log.err("Address must be aligned to 512 bytes, got: {d}", .{address});
            return -1;
        }

        if (buf.len % 512 != 0 or buf.len == 0) {
            log.err("Buffer must be aligned to 512 bytes, got: {d}", .{buf.len});
            return -1;
        }

        const config = self._mmc.get_config();
        if (config.mode == .SDIO) {
            return self.sdio_write(address, buf);
        }

        const block_address = address >> 9;
        const num_blocks = buf.len / 512;
        var i: usize = 0;
        var retransmissions: usize = 0;
        while (i < num_blocks) {
            self.block_write_impl(24, @intCast(block_address + i), buf[512 * i .. 512 * (i + 1)]) catch |err|
                {
                    log.err("Writing block {d} failed with error: {s}, size: {d}", .{ i, @errorName(err), buf.len });
                    if (retransmissions < 3) {
                        retransmissions += 1;
                        continue;
                    } else {
                        log.err("Permanent write error on block {d}: {s}", .{ i, @errorName(err) });
                        return -1;
                    }
                };
            i += 1;
        }

        return @intCast(buf.len);
    }

    pub fn size_in_sectors(self: *const Self) u64 {
        return self._size;
    }

    pub fn initialized(self: *const Self) bool {
        return self._initialized;
    }

    fn reset(self: *const Self) error{MMCResetFailure}!void {
        log.info("resetting", .{});
        const response = self.send_command(0, 0, R1, true);
        if (response.r1 != 0x1) return error.MMCResetFailure;
    }

    fn wait_for_response_r1(self: *const Self) u8 {
        const wait: [1]u8 = [_]u8{0xff};
        var resp: [1]u8 = [_]u8{0x00};
        self._mmc.transmit_blocking(wait[0..], resp[0..]);
        return resp[0];
    }

    fn read_response_r3(self: *const Self) u32 {
        const wait: [4]u8 = [_]u8{0xff} ** 4;
        var resp: [4]u8 = [_]u8{0xff} ** 4;
        self._mmc.transmit_blocking(wait[0..], resp[0..]);
        return std.mem.bigToNative(u32, std.mem.bytesAsValue(u32, &resp).*);
    }

    fn send_command(self: *const Self, cmd: u6, argument: u32, RespType: type, comptime deselect: bool) RespType {
        self._mmc.chip_select(true);
        while (self._initialized and self._mmc.is_busy()) {
            var buffer: [1]u8 = [_]u8{0xff};
            self._mmc.transmit_blocking(buffer[0..], null);
            hal.time.sleep_ms(1);
        }

        const command = self._mmc.build_command(cmd, argument);
        self._mmc.transmit_blocking(command[0..], null);
        var repeat: i32 = 0;
        var resp: RespType = RespType.init();

        while (repeat < 20) {
            const r = self.wait_for_response_r1();
            if ((r & 0x8) == 0) {
                resp.r1 = r;
                if (RespType == R1) {
                    if (deselect) self._mmc.chip_select(false);
                    return resp;
                }
                break;
            }
            repeat += 1;
        }

        if (RespType == R3) {
            resp.ocr = self.read_response_r3();
        }
        if (deselect) self._mmc.chip_select(false);
        return resp;
    }

    fn initiate_intitialization_process(self: *const Self, argument: u32) anyerror!?CardType {
        log.debug("starting initialization with ACMD41", .{});
        var retries: i32 = 0;
        const max_retries: i32 = 100;
        while (retries < max_retries) : (retries += 1) {
            const cmd55_resp = self.send_command(55, 0, R1, true);
            if ((cmd55_resp.r1 & 0xfe) != 0) {
                log.warn("CMD55 returned error bits: 0x{x}", .{cmd55_resp.r1});
                return error.CardInitializationFailure;
            }
            const acmd41_resp = self.send_command(41, argument, R1, true);
            switch (acmd41_resp.r1) {
                0x00 => return CardType.SDv1,
                0x01 => {
                    hal.time.sleep_ms(50);
                },
                else => {
                    log.debug("Incorrect initialization response received ({x})", .{acmd41_resp.r1});
                    return null;
                },
            }
        }
        log.debug("Card didn't respond to ACMD41 after {d} retries", .{max_retries});
        return null;
    }

    fn get_data_token(comptime cmd: u6) !u8 {
        const v: u8 = switch (cmd) {
            9, 10, 17, 18, 28, 24, 6 => 0xfe,
            25 => 0xfc,
            else => {
                log.err("Got unknown packet command: 0x{x}", .{cmd});
                return error.UnknownPacketCommand;
            },
        };
        return v;
    }

    fn receive_data_packet(self: *const Self, comptime cmd: u6, output: []u8) !void {
        const token = try get_data_token(cmd);
        var buffer: [2]u8 = [_]u8{ 0x00, 0x00 };
        var repeat: usize = 100_000;
        while (repeat > 0) : (repeat -= 1) {
            hal.time.sleep_us(1);
            self._mmc.receive_blocking(buffer[0..1]);
            if (buffer[0] == token) break;
            if ((buffer[0] & 0xe0) == 0) {
                return error.GotErrorToken;
            }
        }

        if (token != buffer[0]) {
            log.err("Invalid token received, expected: 0x{x}, got: 0x{x}", .{ token, buffer[0] });
            return error.InvalidToken;
        }

        self._mmc.receive_blocking(output);
        self._mmc.receive_blocking(buffer[0..2]);
        const crc = std.mem.bigToNative(u16, std.mem.bytesToValue(u16, &buffer));
        const received_crc = std.hash.crc.Crc16Xmodem.hash(output);
        if (crc != received_crc) {
            log.debug("Incorrect crc, received: 0x{x}, calculated: 0x{x}", .{ crc, received_crc });
            return error.CrcVerificationFailure;
        }
    }

    fn transmit_data_packet(self: *const Self, comptime cmd: u6, input: []const u8) !void {
        const token = try get_data_token(cmd);
        var buffer: [1]u8 = [_]u8{token};
        const crc = std.hash.crc.Crc16Xmodem.hash(input);
        const native_crc = std.mem.nativeToBig(u16, crc);
        const crc_buffer = std.mem.toBytes(native_crc);

        log.debug("Transmitting data packet with command: {d}, token: {x}, crc: {x}", .{ cmd, token, crc });

        self._mmc.transmit_blocking(buffer[0..], null);
        self._mmc.transmit_blocking(input[0..], null);
        self._mmc.transmit_blocking(crc_buffer[0..2], null);
        self._mmc.receive_blocking(buffer[0..]);
        log.debug("Received response: {x}", .{buffer[0]});

        if (buffer[0] & 0x1f == 0x05) {
            return;
        }

        log.warn("Write response was not successful, received: {x}", .{buffer[0]});
        if (buffer[0] & 0x1f == 0x0b) {
            return error.WriteRejectedCrcError;
        } else if (buffer[0] & 0x1f == 0x0d) {
            return error.WriteRejectedWriteError;
        } else {
            return error.UnknownWriteResponse;
        }
    }

    fn wait_for_card_ready(self: *const Self) !void {
        var timeout: usize = 50_000;
        const dummy: [1]u8 = [_]u8{0xff};
        var resp: [1]u8 = [_]u8{0x00};
        while (timeout > 0) : (timeout -= 1) {
            self._mmc.transmit_blocking(dummy[0..], resp[0..]);
            if (resp[0] == 0xff) {
                return;
            }
            hal.time.sleep_us(10);
        }
        log.err("Timed out waiting for card ready after write", .{});
        return error.CardBusyTimeout;
    }

    fn block_read_impl(self: *const Self, comptime cmd: u6, argument: u32, output: []u8) anyerror!void {
        const cmd_resp = self.send_command(cmd, argument, R1, false);
        errdefer self._mmc.chip_select(false);
        if (cmd_resp.r1 != 0x00) {
            self._mmc.chip_select(false);
            log.err("Received incorrect command response: 0x{x}", .{cmd_resp.r1});
            return error.IncorrectResponse;
        }
        try self.receive_data_packet(cmd, output);
        self._mmc.chip_select(false);

        const dummy: [1]u8 = [_]u8{0xff};
        self._mmc.transmit_blocking(dummy[0..], null);
    }

    fn command_error_bit_to_string(bit: u8) []const u8 {
        return switch (bit) {
            0 => "IdleState",
            1 => "EraseReset",
            2 => "IlligalCommand",
            3 => "CommandCRCError",
            4 => "SequenceError",
            5 => "AddressError",
            6 => "ParameterError",
            else => "Unknown error",
        };
    }

    fn block_write_impl(self: *const Self, comptime cmd: u6, argument: u32, input: []const u8) anyerror!void {
        log.debug("Writing block with command: {d}, argument: {x}", .{ cmd, argument });
        const cmd_resp = self.send_command(cmd, argument, R1, false);
        errdefer self._mmc.chip_select(false);
        if (cmd_resp.r1 != 0x00) {
            self._mmc.chip_select(false);
            log.warn("Received incorrect command response: 0x{x}", .{cmd_resp.r1});
            for (0..8) |i| {
                if (((cmd_resp.r1 >> @as(u3, @intCast(i)) & 1) != 0)) {
                    log.warn("Error bit {d}: {s}", .{ i, command_error_bit_to_string(@as(u8, @intCast(i))) });
                }
            }
            return error.IncorrectResponse;
        }
        // const dummy: [1]u8 = [_]u8{0xff};
        // self._mmc.transmit_blocking(dummy[0..], null);

        try self.transmit_data_packet(cmd, input);
        try self.wait_for_card_ready();
        self._mmc.chip_select(false);

        const dummy: [1]u8 = [_]u8{0xff};
        self._mmc.transmit_blocking(dummy[0..], null);
    }

    fn read_cid(self: *Self) !card_parser.CID {
        var buffer: [16]u8 = [_]u8{0x00} ** 16;
        try self.block_read_impl(10, 0, buffer[0..]);
        log.info("Got CID: {any}", .{buffer});
        return std.mem.bytesToValue(card_parser.CID, &buffer);
    }

    fn read_csd(self: *Self) !card_parser.CSDv2 {
        var buffer: [16]u8 = [_]u8{0x00} ** 16;
        try self.block_read_impl(9, 0, buffer[0..]);
        return try card_parser.CardParser.parse_csdv2(buffer[0..]);
    }

    fn dump_struct(t: anytype) void {
        log.debug("{s}", .{@typeName(@TypeOf(t))});
        inline for (std.meta.fields(@TypeOf(t))) |f| {
            if (@FieldType(@TypeOf(t), f.name) == bool) {
                log.debug("  {s}: {}", .{ f.name, @field(t, f.name) });
            } else {
                log.debug("  {s}: {x}", .{ f.name, @field(t, f.name) });
            }
        }
    }

    /// One CMD0 / CMD8 / ACMD41 bring-up attempt. Null means the card answered
    /// but never reported itself powered up, which is the case worth retrying
    /// from CMD0; an error means it did not answer usably at all.
    fn try_sdio_card_ready(self: *Self) anyerror!?CardType {
        // A CMD12 STOP_TRANSMISSION was tried here, on the theory that bring-up
        // was meeting a card left mid-read by the previous session (a card in
        // that state answers nothing else). It changed nothing -- 85% of boots
        // still failed -- because the command was not reaching the card at all:
        // see the autopull race in rp2350_sdio_command. Not kept, since on an
        // idle card it is an illegal-state command that costs a timeout and an
        // error line on every boot.
        //
        // GO_IDLE, then let the card settle. Deliberately one CMD0: issuing a
        // burst of them measured strictly worse (five bring-ups out of five
        // failed, against one in four for a single CMD0), so whatever state the
        // card is in, hammering GO_IDLE does not improve it.
        _ = self._mmc.send_sdio_command(0, 0);
        hal.time.sleep_ms(10);

        const cmd8_resp = self._mmc.send_sdio_command(8, 0x000001aa);
        if ((cmd8_resp.card_status & 0xfff) != 0x1aa) {
            log.err("CMD8 voltage check failed, response: 0x{x}", .{cmd8_resp.card_status});
            return error.CardInitializationFailure;
        }

        // 200 x 10 ms = 2 s per attempt, twice the initialisation time the spec
        // allows a card. The observed failure is not a card that is slow, it is
        // a card that answers ACMD41 with the busy bit set forever, so a longer
        // wait buys nothing that the caller's retry from CMD0 does not.
        var retries: u32 = 0;
        const max_retries: u32 = 200;
        while (retries < max_retries) : (retries += 1) {
            const cmd55_resp = self._mmc.send_sdio_command(55, 0);
            const acmd41_resp = self._mmc.send_sdio_command(41, 0x40ff8000);
            if ((acmd41_resp.card_status & 0x80000000) != 0) {
                return if ((acmd41_resp.card_status & 0x40000000) != 0)
                    CardType.SDv2Block
                else
                    CardType.SDv2Byte;
            }
            if (retries + 1 == max_retries) {
                // Three outcomes to tell apart, and they have different causes.
                // A plausible OCR with the busy bit clear means the card is
                // talking and simply not ready. A zero response with ok=false
                // means the driver rejected the reply (timeout, CRC, or wrong
                // command tag) -- and since CMD55 is checked with both CRC and
                // tag while ACMD41 is checked with neither, a CMD55 that fails
                // here takes ACMD41 down with it, because the card never sees
                // the next command as an application command at all.
                log.err("ACMD41 never ready: cmd55 ok={} status=0x{x}, acmd41 ok={} status=0x{x}", .{
                    cmd55_resp.crc_ok,  cmd55_resp.card_status,
                    acmd41_resp.crc_ok, acmd41_resp.card_status,
                });
            }
            hal.time.sleep_ms(10);
        }
        return null;
    }

    fn initialize_sdio_mmc(self: *Self) anyerror!void {
        log.info("initializing MMC using SDIO (native) mode", .{});

        // Bring-up is retried from CMD0 rather than attempted once. A card that
        // was mid-transfer when the board reset -- the SD supply is not cycled
        // by a reset, so it keeps whatever state it was in -- can answer ACMD41
        // with the busy bit indefinitely, and only a fresh GO_IDLE clears it.
        // This became visible when the HAL started being built optimised and
        // boot began reaching this code milliseconds after reset instead of
        // comfortably later: bring-up failed roughly one run in four.
        var attempt: u32 = 0;
        const max_attempts: u32 = 3;
        while (attempt < max_attempts) : (attempt += 1) {
            self._card_type = try self.try_sdio_card_ready();
            if (self._card_type != null) break;
            log.err("SDIO bring-up attempt {d} timed out on ACMD41, restarting from CMD0", .{attempt});
        }

        if (self._card_type == null) {
            log.err("Card did not respond to ACMD41 after {d} attempts", .{max_attempts});
            return error.CardInitializationFailure;
        }

        log.info("Found card with type: {s}", .{@tagName(self._card_type.?)});

        const cid_resp = self._mmc.send_sdio_command_long(2, 0);
        if (!cid_resp.valid) {
            log.warn("CID response invalid", .{});
        }

        const cmd3_resp = self._mmc.send_sdio_command(3, 0);
        const rca: u16 = @intCast(cmd3_resp.card_status >> 16);
        self._rca = rca;
        log.info("Card RCA: 0x{x}", .{rca});

        const csd_resp = self._mmc.send_sdio_command_long(9, @as(u32, rca) << 16);
        if (csd_resp.valid) {
            const csd = card_parser.CardParser.parse_csdv2(&csd_resp.data) catch |err| {
                log.err("Failed to parse CSD: {s}", .{@errorName(err)});
                return err;
            };
            self._size = csd.get_size() / csd.get_sector_size();
            dump_struct(csd);
        }

        const cmd7_resp = self._mmc.send_sdio_command(7, @as(u32, rca) << 16);
        if (cmd7_resp.command_index != 7) {
            log.warn("Unexpected CMD7 response index: {d}", .{cmd7_resp.command_index});
        }

        try self.set_sdio_bus_width_4bit(rca);

        const high_speed_enabled = hs: {
            const enabled = self.try_enable_sdio_high_speed(rca) catch |err| {
                log.warn("CMD6 high-speed switch failed: {s}", .{@errorName(err)});
                break :hs false;
            };
            break :hs enabled;
        };
        self._mmc.change_speed_to(if (high_speed_enabled) 50 * 1000 * 1000 else 25 * 1000 * 1000);

        const cmd16_resp = self._mmc.send_sdio_command(16, 512);
        if (cmd16_resp.command_index != 16) {
            log.err("CMD16 SET_BLOCKLEN failed during init", .{});
            return error.CardInitializationFailure;
        }

        self._initialized = true;
        log.info("SDIO initialization complete, size: {d} sectors", .{self._size});
    }

    /// ACMD6 SET_BUS_WIDTH argument for four data lines.
    const sd_bus_width_4bit: u32 = 0x0000_0002;

    /// Put the card on all four data lines, and do not proceed until it says so.
    ///
    /// The host reads DAT3..DAT0 unconditionally -- `set_wide_bus` is a no-op
    /// because the PIO program has no 1-bit mode -- so a card left in 1-bit is
    /// not slower, it is unreadable. Three lines idle high and every nibble
    /// comes back `0xE`, which is the `0xeeeeeeee` + `DataCrc` signature that
    /// ends in "Invalid MBR found" with the card otherwise perfectly healthy.
    ///
    /// This used to be two `_ =` discarded calls. A soak (20 resets,
    /// `tests/smoke/sd_bringup_soak_test.py`) showed the whole failure riding on
    /// them: one dropped response is common and survivable everywhere else in
    /// bring-up, because everything else is either retried or checked -- but a
    /// dropped CMD55 or ACMD6 silently left the card and the host disagreeing
    /// about the bus, and nothing downstream could recover.
    ///
    /// ACMD41's own retry loop is the precedent for the shape: re-issue the
    /// pair rather than fail, since what is being worked around is a lost
    /// response, not a card that refuses.
    fn set_sdio_bus_width_4bit(self: *Self, rca: u16) !void {
        const max_attempts: u32 = 3;
        var attempt: u32 = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            if (attempt > 0) {
                hal.time.sleep_ms(1);
            }
            // CMD55 is what makes the next command an *application* command.
            // If it is lost the card reads the ACMD6 that follows as CMD6
            // SWITCH_FUNC instead, so its response says nothing about the bus
            // width and must not be trusted on its own.
            const app_resp = self._mmc.send_sdio_command(55, @as(u32, rca) << 16);
            if (!app_resp.crc_ok or app_resp.command_index != 55) {
                log.warn("CMD55 before ACMD6 failed (attempt {d})", .{attempt});
                continue;
            }
            const width_resp = self._mmc.send_sdio_command(6, sd_bus_width_4bit);
            if (!width_resp.crc_ok or width_resp.command_index != 6) {
                log.warn("ACMD6 SET_BUS_WIDTH failed (attempt {d})", .{attempt});
                continue;
            }
            self._mmc.set_wide_bus(true);
            if (attempt > 0) {
                log.warn("ACMD6 SET_BUS_WIDTH needed {d} attempts", .{attempt + 1});
            }
            return;
        }
        log.err("Card never acknowledged ACMD6 SET_BUS_WIDTH; refusing to read a 4-bit bus from a 1-bit card", .{});
        return error.CardInitializationFailure;
    }

    fn build_sd_switch_arg(mode: u32, group: u32, value: u32) u32 {
        var arg: u32 = (mode << 31) | 0x00ff_ffff;
        arg &= ~(@as(u32, 0xf) << @intCast(group * 4));
        arg |= value << @intCast(group * 4);
        return arg;
    }

    fn verify_sdio_transfer_mode(self: *Self, rca: u16) bool {
        const status_resp = self._mmc.send_sdio_command(13, @as(u32, rca) << 16);
        if (status_resp.command_index != 13) {
            log.warn("CMD13 failed after SDIO speed change, falling back", .{});
            return false;
        }
        return true;
    }

    fn try_enable_sdio_high_speed(self: *Self, rca: u16) !bool {
        var status: [64]u8 align(4) = [_]u8{0} ** 64;

        const check_arg = build_sd_switch_arg(sd_switch_check, sd_switch_group_access, sd_switch_access_default);
        const check_resp = self._mmc.send_sdio_data_command(6, check_arg);
        if (check_resp.command_index != 6) {
            return error.CardInitializationFailure;
        }
        try self._mmc.read_sdio_data(status[0..]);
        if ((status[13] & 0x02) == 0) {
            log.info("SD card does not advertise high-speed mode support", .{});
            return false;
        }

        const switch_arg = build_sd_switch_arg(sd_switch_set, sd_switch_group_access, sd_switch_access_high_speed);
        const switch_resp = self._mmc.send_sdio_data_command(6, switch_arg);
        if (switch_resp.command_index != 6) {
            return error.CardInitializationFailure;
        }
        try self._mmc.read_sdio_data(status[0..]);
        if ((status[16] & 0x0f) != sd_switch_access_high_speed) {
            log.warn("SD card rejected CMD6 high-speed switch (status=0x{x})", .{status[16]});
            return false;
        }

        self._mmc.change_speed_to(50 * 1000 * 1000);
        if (!self.verify_sdio_transfer_mode(rca)) {
            self._mmc.change_speed_to(25 * 1000 * 1000);
            return false;
        }

        log.info("SD card switched to high-speed mode via CMD6", .{});
        return true;
    }

    const sdio_io_retry_limit: usize = 6;

    fn wait_for_card_dat0(self: *const Self) void {
        var timeout: u32 = 100_000;
        while (self._mmc.is_busy() and timeout > 0) : (timeout -= 1) {
            hal.time.sleep_us(10);
        }
        if (timeout == 0) {
            log.warn("DAT0 busy timeout waiting for card ready", .{});
        }
    }

    fn sdio_read(self: *const Self, address: u64, buf: []u8) isize {
        const block_address: u32 = @intCast(address >> 9);
        const num_blocks = buf.len / 512;
        const max_blocks_per_req = 128;

        var i: usize = 0;
        var retransmissions: usize = 0;
        while (i < num_blocks) {
            const remaining = num_blocks - i;
            const chunk: u32 = @intCast(if (remaining > max_blocks_per_req) max_blocks_per_req else remaining);

            self.wait_for_card_dat0();

            if (chunk == 1) {
                const resp = self._mmc.send_sdio_command(17, @intCast(block_address + i));
                if (resp.command_index != 17) {
                    if (retransmissions < sdio_io_retry_limit) {
                        retransmissions += 1;
                        continue;
                    }
                    log.err("SDIO read failed permanently: CMD17 did not respond for block {d} after {d} retries", .{ i, retransmissions });
                    return -1;
                }

                self._mmc.read_sdio_data(buf[512 * i .. 512 * (i + 1)]) catch |err| {
                    if (retransmissions < sdio_io_retry_limit) {
                        retransmissions += 1;
                        continue;
                    }
                    log.err("SDIO read failed permanently: block {d} returned {s} after {d} retries", .{ i, @errorName(err), retransmissions });
                    return -1;
                };
                i += 1;
            } else {
                const resp = self._mmc.send_sdio_command(18, @intCast(block_address + i));
                if (resp.command_index != 18) {
                    if (retransmissions < sdio_io_retry_limit) {
                        retransmissions += 1;
                        continue;
                    }
                    log.err("SDIO multi-read failed permanently: CMD18 did not respond at block {d} after {d} retries", .{ i, retransmissions });
                    return -1;
                }

                self._mmc.read_sdio_data(buf[512 * i .. 512 * (i + chunk)]) catch |err| {
                    _ = self._mmc.send_sdio_command(12, 0);
                    if (retransmissions < sdio_io_retry_limit) {
                        retransmissions += 1;
                        continue;
                    }
                    log.err("SDIO multi-read failed permanently: {d} blocks at {d} returned {s} after {d} retries", .{ chunk, i, @errorName(err), retransmissions });
                    return -1;
                };

                _ = self._mmc.send_sdio_command(12, 0);
                i += chunk;
            }
            retransmissions = 0;
        }

        return @intCast(buf.len);
    }

    /// ACMD23: tell the card how many blocks the next CMD25 will write, so the
    /// pre-erase happens once for the whole run.
    ///
    /// Silent on failure by design. It is a hint, not part of the write: a card
    /// that rejects CMD55 or answers ACMD23 with the wrong index still stores
    /// every byte the following CMD25 sends. Logging here would put a line on
    /// the console for every chunk of every write on such a card, which is a
    /// worse outcome than the lost optimisation.
    fn set_write_block_erase_count(self: *const Self, blocks: u32) void {
        const cmd55_resp = self._mmc.send_sdio_command(55, @as(u32, self._rca) << 16);
        if (cmd55_resp.command_index != 55) {
            return;
        }
        _ = self._mmc.send_sdio_command(23, blocks);
    }

    /// Note on where a write's time actually goes, measured 2026-08-06.
    ///
    /// FatFs clips every disk_write at the cluster boundary (ff.c, "Clip at
    /// cluster boundary"), so with this volume's 16-sector cluster a 32 KiB
    /// user write arrives here as *four* separate 8 KiB requests. Profiling the
    /// block loop showed the transfer itself is already efficient -- 21 us per
    /// 512-byte block against 21.5 us of bus time, with the per-block PIO
    /// restart costing ~0.3 us and the card's status-plus-busy window 15-40 us.
    /// What dominates is the ~1019 us of fixed cost each *request* pays outside
    /// that loop: 57% of the write. Cutting four requests to one would be worth
    /// roughly 1.74x, and the only lever for that is the cluster size chosen at
    /// mkfs time -- there is no FatFs configuration for it.
    fn sdio_write(self: *const Self, address: u64, buf: []const u8) isize {
        const block_address: u32 = @intCast(address >> 9);
        const num_blocks = buf.len / 512;
        const max_blocks_per_req = 128;

        var i: usize = 0;
        var retransmissions: usize = 0;
        while (i < num_blocks) {
            const remaining = num_blocks - i;
            const chunk: u32 = @intCast(if (remaining > max_blocks_per_req) max_blocks_per_req else remaining);

            self.wait_for_card_dat0();

            if (chunk == 1) {
                const resp = self._mmc.send_sdio_command(24, @intCast(block_address + i));
                if (resp.command_index != 24) {
                    if (retransmissions < sdio_io_retry_limit) {
                        retransmissions += 1;
                        continue;
                    }
                    log.err("SDIO write failed permanently: CMD24 response mismatch for block {d} after {d} retries", .{ i, retransmissions });
                    return -1;
                }

                self._mmc.write_sdio_data(buf[512 * i .. 512 * (i + 1)]) catch |err| {
                    _ = self._mmc.send_sdio_command(12, 0);
                    if (retransmissions < sdio_io_retry_limit) {
                        retransmissions += 1;
                        continue;
                    }
                    log.err("SDIO write failed permanently: block {d} returned {s} after {d} retries", .{ i, @errorName(err), retransmissions });
                    return -1;
                };
            } else {
                // ACMD23 SET_WR_BLK_ERASE_COUNT, which the spec wants issued
                // immediately before CMD25: it tells the card how many blocks
                // are coming so the pre-erase happens once rather than being
                // discovered block by block. Advisory -- a card that declines it
                // stores exactly the same data, so a failed response is stepped
                // over rather than retried.
                //
                // Measured neutral on this card, twice (adding it changed
                // nothing; removing it changed nothing, 4435 -> 4467 KiB/s
                // against a 3993-4542 run-to-run band). It is kept because it is
                // what the spec asks for and may matter on another card, not
                // because it was shown to pay here. The write path's real cost
                // is elsewhere -- see set_write_block_erase_count's caller notes
                // and the cluster-size note in sdio_write.
                self.set_write_block_erase_count(chunk);

                // CMD25 multi-block: the card pipelines programming behind the
                // transfer, so the program time that CMD24 pays per sector is
                // paid once per chunk. A failed chunk is retried whole from
                // its first block; rewriting sectors that already made it is
                // the same data to the same place.
                const resp = self._mmc.send_sdio_command(25, @intCast(block_address + i));
                if (resp.command_index != 25) {
                    if (retransmissions < sdio_io_retry_limit) {
                        retransmissions += 1;
                        continue;
                    }
                    log.err("SDIO multi-write failed permanently: CMD25 did not respond at block {d} after {d} retries", .{ i, retransmissions });
                    return -1;
                }

                self._mmc.write_sdio_data(buf[512 * i .. 512 * (i + chunk)]) catch |err| {
                    _ = self._mmc.send_sdio_command(12, 0);
                    self.wait_for_card_dat0();
                    if (retransmissions < sdio_io_retry_limit) {
                        retransmissions += 1;
                        continue;
                    }
                    log.err("SDIO multi-write failed permanently: {d} blocks at {d} returned {s} after {d} retries", .{ chunk, i, @errorName(err), retransmissions });
                    return -1;
                };

                _ = self._mmc.send_sdio_command(12, 0);
            }

            var timeout: u32 = 100_000;
            while (self._mmc.is_busy() and timeout > 0) : (timeout -= 1) {
                hal.time.sleep_us(10);
            }
            if (timeout == 0) {
                log.err("Card busy timeout after write block {d}", .{i});
                return -1;
            }

            i += chunk;
            retransmissions = 0;
        }

        return @intCast(buf.len);
    }

    fn initialize_spi_mmc(self: *Self) anyerror!void {
        log.info("initializing MMC using SPI mode", .{});
        self.reset() catch return error.CardInitializationFailure;
        log.debug("sending CMD8", .{});
        const cmd8_resp = self.send_command(8, 0x1aa, R7, true);
        if (cmd8_resp.r1 != 0x1) {
            log.debug("CMD8 was rejected with response code: 0x{x}, trying ACMD41", .{cmd8_resp.r1});
            self._card_type = try self.initiate_intitialization_process(0);
            if (self._card_type == null) {
                var retries: i32 = 0;
                while (retries < 10) {
                    const cmd1_resp = self.send_command(1, 0, R1, true);
                    if (cmd1_resp.r1 == 0x00) {
                        self._card_type = CardType.MMCv3;
                    } else if (cmd1_resp.r1 != 0x01) {
                        log.err("CMD1 responded with response code ({x})", .{cmd1_resp.r1});
                        return error.UnknownCard;
                    }
                    retries += 1;
                }
            }
        } else {
            if ((cmd8_resp.ocr & 0xfff) == 0x1aa) {
                self._card_type = try self.initiate_intitialization_process(0x40000000);
                if (self._card_type != null) {
                    const cmd58_resp = self.send_command(58, 0, R3, true);
                    if (cmd58_resp.r1 == 0) {
                        if ((cmd58_resp.ocr & 0x40000000) == 0) {
                            self._card_type = CardType.SDv2Byte;
                        } else {
                            self._card_type = CardType.SDv2Block;
                        }
                    } else {
                        log.err("incorrect R1 for CMD58: 0x{x}", .{cmd58_resp.r1});
                        return error.UnknownCard;
                    }
                } else {
                    log.err("Card didn't respond to ACMD41 during SDv2 initialization", .{});
                    return error.UnknownCard;
                }
            } else {
                log.err("Unknown card type, CMD8 R1({x}) R7({x})", .{ cmd8_resp.r1, cmd8_resp.ocr });
                return error.UnknownCard;
            }
        }

        if (self._card_type) |card_type| {
            log.info("Found card with type: {s}", .{@tagName(card_type)});
            var change_buffer: [64]u8 = [_]u8{0x00} ** 64;
            const resp = try self.block_read_impl(6, 0x80000001, change_buffer[0..]);
            _ = resp; // we don't care about the response here, just that it worked
        }
        log.info("Detecting card properties", .{});
        const csd = try self.read_csd();
        self._size = csd.get_size() / csd.get_sector_size();
        dump_struct(csd);
        self._mmc.change_speed_to(csd.get_speed() / 4); // increase me after retransmission implementation
        self._initialized = true;
    }
};

var mmc_stub = hal.mmc.Mmc.create(.{
    .pins = .{
        .clk = 0,
        .cmd = 1,
        .d0 = 2,
    },
    .mode = .SPI,
});

fn consume_frame(maybe_expected: ?[]const u8) !void {
    // do nothing
    const frame = mmc_stub.impl.get_transmit_data();
    defer std.testing.allocator.free(frame);
    if (maybe_expected) |expected| {
        try std.testing.expectEqualSlices(u8, expected, frame);
    }
}

test "MmcIo.ShouldInitializeInterface" {
    var sut = MmcIo.create(&mmc_stub);
    mmc_stub.impl.reset();
    defer mmc_stub.impl.reset();

    try mmc_stub.impl.init();
    const R1_IDLE_RESP = [_]u8{0x01};
    const R7_RESP = [_]u8{ 0x01, 0x00, 0x01, 0xaa };
    const R1_RESP = [_]u8{0x00};
    const R3_RESP = [_]u8{ 0x40, 0x00, 0x00, 0x00 };

    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R7_RESP);
    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&R3_RESP);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    const TOKEN_READ: [1]u8 = [_]u8{0xfe};
    try mmc_stub.impl.set_receive_data(&TOKEN_READ);
    try mmc_stub.impl.set_receive_data(&[_]u8{0x00} ** 16);
    try mmc_stub.impl.set_receive_data(&[_]u8{ 0x00, 0x00 }); // crc
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&TOKEN_READ);
    const csd_bytes: [16]u8 = [_]u8{
        0x40, 0x0E, 0x00, 0x32, 0x5B, 0x59, 0x00, 0x00,
        0x74, 0xcb, 0x7f, 0x80, 0x0a, 0x40, 0x00, 0x3d,
    };

    try mmc_stub.impl.set_receive_data(csd_bytes[0..]);
    try mmc_stub.impl.set_receive_data(&[_]u8{ 0xe1, 0xf8 }); // crc

    try sut.init();

    try consume_frame(&[_]u8{ 0x40, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x48, 0, 0, 1, 0xaa, 0x95 });
    try consume_frame(null);
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x77, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x69, 0x40, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x7a, 0x00, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x46, 0x80, 0, 0, 0x1, 0x95 });
    try consume_frame(null);
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x49, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(null);

    try mmc_stub.impl.verify();
    try std.testing.expect(sut.initialized());

    try std.testing.expectEqual(30617600, sut.size_in_sectors());
    try std.testing.expectEqual(sut._card_type.?, CardType.SDv2Block);
}

test "MmcIo.ShouldInitializeInterfaceWithSDV2Byte" {
    var sut = MmcIo.create(&mmc_stub);
    mmc_stub.impl.reset();
    defer mmc_stub.impl.reset();

    try mmc_stub.impl.init();
    const R1_IDLE_RESP = [_]u8{0x01};
    const R7_RESP = [_]u8{ 0x01, 0x00, 0x01, 0xaa };
    const R1_RESP = [_]u8{0x00};
    const R3_RESP = [_]u8{ 0x00, 0x00, 0x00, 0x00 };

    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R7_RESP);
    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&R3_RESP);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    const TOKEN_READ: [1]u8 = [_]u8{0xfe};
    try mmc_stub.impl.set_receive_data(&TOKEN_READ);
    try mmc_stub.impl.set_receive_data(&[_]u8{0x00} ** 16);
    try mmc_stub.impl.set_receive_data(&[_]u8{ 0x00, 0x00 }); // crc
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&TOKEN_READ);
    const csd_bytes: [16]u8 = [_]u8{
        0x40, 0x0E, 0x00, 0x32, 0x5B, 0x59, 0x00, 0x00,
        0x74, 0xcb, 0x7f, 0x80, 0x0a, 0x40, 0x00, 0x3d,
    };

    try mmc_stub.impl.set_receive_data(csd_bytes[0..]);
    try mmc_stub.impl.set_receive_data(&[_]u8{ 0xe1, 0xf8 }); // crc

    try sut.init();

    try consume_frame(&[_]u8{ 0x40, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x48, 0, 0, 1, 0xaa, 0x95 });
    try consume_frame(null);
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x77, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x69, 0x40, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x7a, 0x00, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x46, 0x80, 0, 0, 0x1, 0x95 });
    try consume_frame(null);
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x49, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(null);

    try mmc_stub.impl.verify();
    try std.testing.expect(sut.initialized());

    try std.testing.expectEqual(30617600, sut.size_in_sectors());
    try std.testing.expectEqual(sut._card_type.?, CardType.SDv2Byte);
}

test "MmcIo.ShouldHandleIncorrectCMD8Response" {
    var sut = MmcIo.create(&mmc_stub);
    mmc_stub.impl.reset();
    defer mmc_stub.impl.reset();

    try mmc_stub.impl.init();
    const R1_IDLE_RESP = [_]u8{0x01};
    const R7_RESP = [_]u8{ 0x01, 0x00, 0x00, 0xaa };

    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R7_RESP);

    try std.testing.expectEqual(error.UnknownCard, sut.init());

    try consume_frame(&[_]u8{ 0x40, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x48, 0, 0, 1, 0xaa, 0x95 });
    try consume_frame(null);
    try consume_frame(null);

    try mmc_stub.impl.verify();
    try std.testing.expect(!sut.initialized());
}

test "MmcIo.ShouldInitializeWithACMD41" {
    var sut = MmcIo.create(&mmc_stub);
    mmc_stub.impl.reset();
    defer mmc_stub.impl.reset();

    try mmc_stub.impl.init();
    const R1_IDLE_RESP = [_]u8{0x01};
    const R7_RESP = [_]u8{ 0x01, 0x00, 0x01, 0xaa };
    const R1_RESP = [_]u8{0x00};

    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&R7_RESP);
    try mmc_stub.impl.set_receive_data(&R1_IDLE_RESP);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    const TOKEN_READ: [1]u8 = [_]u8{0xfe};
    try mmc_stub.impl.set_receive_data(&TOKEN_READ);
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&[_]u8{ 0x00, 0x00 }); // crc
    try mmc_stub.impl.set_receive_data(&R1_RESP);
    try mmc_stub.impl.set_receive_data(&TOKEN_READ);
    const csd_bytes: [16]u8 = [_]u8{
        0x40, 0x0E, 0x00, 0x32, 0x5B, 0x59, 0x00, 0x00,
        0x74, 0xcb, 0x7f, 0x80, 0x0a, 0x40, 0x00, 0x3d,
    };

    try mmc_stub.impl.set_receive_data(csd_bytes[0..]);
    try mmc_stub.impl.set_receive_data(&[_]u8{ 0xe1, 0xf8 }); // crc

    try sut.init();

    try consume_frame(&[_]u8{ 0x40, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x48, 0, 0, 1, 0xaa, 0x95 });
    try consume_frame(null);
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x77, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x69, 0x00, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x46, 0x80, 0, 0, 0x1, 0x95 });
    try consume_frame(null);
    try consume_frame(null);
    try consume_frame(&[_]u8{ 0x49, 0, 0, 0, 0, 0x95 });
    try consume_frame(null);
    try consume_frame(null);

    try mmc_stub.impl.verify();
    try std.testing.expect(sut.initialized());

    try std.testing.expectEqual(30617600, sut.size_in_sectors());
    try std.testing.expectEqual(sut._card_type.?, CardType.SDv1);
}
