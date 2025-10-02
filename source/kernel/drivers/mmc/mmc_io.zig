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

pub const MmcIo = struct {
    const Self = @This();
    _mmc: hal.mmc.Mmc,
    _card_type: ?CardType,
    _size: u32,
    _initialized: bool,

    pub fn create(mmc: hal.mmc.Mmc) MmcIo {
        return .{
            ._mmc = mmc,
            ._card_type = null,
            ._size = 0,
            ._initialized = false,
        };
    }

    pub fn init(self: *Self) anyerror!void {
        try self._mmc.init();
        const config = self._mmc.get_config();
        switch (config.mode) {
            .SPI => {
                self.initialize_spi_mmc() catch |err| {
                    log.info("initialization failed with an error: {s}", .{@errorName(err)});
                };
            },
            else => {
                log.err("Unsupported mode in config", .{});
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

    pub fn read(self: Self, address: usize, buf: []u8) isize {
        if (address % 512 != 0) {
            log.err("Address must be aligned to 512 bytes, got: {d}", .{address});
            return -1;
        }

        if (buf.len % 512 != 0 or buf.len == 0) {
            log.err("Buffer must be aligned to 512 bytes, got: {d}", .{buf.len});
            return -1;
        }

        const block_address = address >> 9;
        const num_blocks = buf.len / 512;
        var i: usize = 0;
        while (i < num_blocks) : (i += 1) {
            self.block_read_impl(17, block_address + i, buf[512 * i .. 512 * (i + 1)]) catch return -1;
        }

        return @intCast(buf.len);
    }

    pub fn write(self: Self, address: usize, buf: []const u8) isize {
        if (address % 512 != 0) {
            log.err("Address must be aligned to 512 bytes, got: {d}", .{address});
            return -1;
        }

        if (buf.len % 512 != 0 or buf.len == 0) {
            log.err("Buffer must be aligned to 512 bytes, got: {d}", .{buf.len});
            return -1;
        }

        const block_address = address >> 9;
        const num_blocks = buf.len / 512;
        var i: usize = 0;
        while (i < num_blocks) : (i += 1) {
            self.block_write_impl(24, block_address + i, buf[512 * i .. 512 * (i + 1)]) catch return -1;
        }

        return @intCast(buf.len);
    }

    pub fn size_in_sectors(self: *const Self) u32 {
        return self._size;
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
        while (retries < 10) {
            hal.time.sleep_ms(150);
            const cmd55_resp = self.send_command(55, 0, R1, true);
            if (cmd55_resp.r1 != 0x1) {
                return error.CardInitializationFailure;
            }
            const acmd41_resp = self.send_command(41, argument, R1, true);
            if (acmd41_resp.r1 == 0x00) {
                return CardType.SDv1;
            } else if (acmd41_resp.r1 != 0x01) {
                log.debug("Incorrect initialization response received ({x})", .{acmd41_resp.r1});
                return null;
            }
            retries += 1;
        }
        log.debug("Card didn't respond to ACMD41", .{});
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

    fn receive_data_packet(self: Self, comptime cmd: u6, output: []u8) !void {
        const token = try get_data_token(cmd);
        var buffer: [2]u8 = [_]u8{ 0x00, 0x00 };
        var repeat: i32 = 1000;
        while (repeat > 0) {
            hal.time.sleep_us(1);
            self._mmc.receive_blocking(buffer[0..1]);
            if (buffer[0] == token) break;
            if ((buffer[0] & 0xe0) == 0) {
                return error.GotErrorToken;
            }
            repeat -= 1;
        }

        if (token != buffer[0] and repeat == 0) {
            log.err("Invalid token received, expected: 0x{x}, got: 0x{x}", .{ token, buffer[0] });
        }

        self._mmc.receive_blocking(output);
        self._mmc.receive_blocking(buffer[0..2]);
        const crc = std.mem.bigToNative(u16, std.mem.bytesToValue(u16, &buffer));
        const received_crc = std.hash.crc.Crc16Xmodem.hash(output);
        if (crc != received_crc) {
            log.err("Incorrect crc, received: 0x{x}, calculated: 0x{x}", .{ crc, received_crc });
            return error.CrcVerificationFailure;
        }
    }

    fn transmit_data_packet(self: Self, comptime cmd: u6, input: []const u8) !void {
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

    fn block_read_impl(self: Self, comptime cmd: u6, argument: u32, output: []u8) anyerror!void {
        const cmd_resp = self.send_command(cmd, argument, R1, false);
        errdefer self._mmc.chip_select(false);
        if (cmd_resp.r1 != 0x00) {
            self._mmc.chip_select(false);
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

    fn block_write_impl(self: Self, comptime cmd: u6, argument: u32, input: []const u8) anyerror!void {
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
        self._mmc.chip_select(false);

        // self._mmc.transmit_blocking(dummy[0..], null);
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
                        log.warn("CMD1 responded with response code ({x})", .{cmd1_resp.r1});
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
                        log.warn("incorrect R1 for CMD58: 0x{x}", .{cmd58_resp.r1});
                        return error.UnknownCard;
                    }
                } else {
                    return error.UnknownCard;
                }
            } else {
                log.warn("Unknown card type, CMD8 R1({x}) R7({x})", .{ cmd8_resp.r1, cmd8_resp.ocr });
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
        self._mmc.change_speed_to(csd.get_speed() / 4);
        self._initialized = true;
    }
};
