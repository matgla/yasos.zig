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

const IDriver = @import("../idriver.zig").IDriver;
const IFile = @import("../../fs/fs.zig").IFile;
const MmcFile = @import("mmc_file.zig").MmcFile;

const interface = @import("interface");

const hal = @import("hal");

const log = std.log.scoped(.@"mmc/driver");

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

pub const MmcDriver = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();
    _mmc: hal.mmc.Mmc,
    _name: []const u8,
    _card_type: ?CardType,

    pub fn create(mmc: hal.mmc.Mmc, driver_name: []const u8) MmcDriver {
        return MmcDriver.init(.{
            ._mmc = mmc,
            ._name = driver_name,
            ._card_type = null,
        });
    }

    pub fn ifile(self: *Self, allocator: std.mem.Allocator) ?IFile {
        const file = MmcFile.InstanceType.create(&self._mmc, allocator, self._name).interface.new(allocator) catch return null;
        return file;
    }

    pub fn load(self: *Self) anyerror!void {
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

    pub fn unload(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    fn reset(self: *const Self) error{MMCResetFailure}!void {
        log.info("resetting", .{});
        const response = self.send_command(0, 0, R1);
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

    fn send_command(self: *const Self, cmd: u6, argument: u32, RespType: type) RespType {
        self._mmc.chip_select(true);
        defer self._mmc.chip_select(false);
        const command = self._mmc.build_command(cmd, argument);
        self._mmc.transmit_blocking(command[0..], null);
        var repeat: i32 = 0;
        var resp: RespType = RespType.init();

        while (repeat < 20) {
            const r = self.wait_for_response_r1();
            if ((r & 0x8) == 0) {
                log.info("GOT r1 {x}", .{r});
                resp.r1 = r;
                if (RespType == R1) {
                    return resp;
                }
                break;
            }
            repeat += 1;
        }

        if (RespType == R3) {
            log.info("Getting R3 reponse", .{});
            resp.ocr = self.read_response_r3();
        }
        return resp;
    }

    fn initiate_intitialization_process(self: *const Self, argument: u32) anyerror!?CardType {
        log.debug("starting initialization with ACMD41", .{});
        var retries: i32 = 0;
        while (retries < 10) {
            hal.time.sleep_ms(100);
            const cmd55_resp = self.send_command(55, 0, R1);
            if (cmd55_resp.r1 != 0x1) {
                return error.CardInitializationFailure;
            }
            const acmd41_resp = self.send_command(41, argument, R1);
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

    fn initialize_spi_mmc(self: *Self) anyerror!void {
        log.info("initializing MMC using SPI mode", .{});
        self.reset() catch return error.CardInitializationFailure;
        const cmd8_resp = self.send_command(8, 0x1aa, R7);
        if (cmd8_resp.r1 != 0x1) {
            log.debug("CMD8 was rejected with response code: 0x{x}, trying ACMD41", .{cmd8_resp.r1});
            self._card_type = try self.initiate_intitialization_process(0);
            if (self._card_type == null) {
                var retries: i32 = 0;
                while (retries < 10) {
                    const cmd1_resp = self.send_command(1, 0, R1);
                    if (cmd1_resp.r1 == 0x00) {
                        self._card_type = CardType.MMCv3;
                    } else if (cmd1_resp.r1 != 0x01) {
                        log.warn("CMD1 responded with response code ({x})", .{cmd1_resp.r1});
                        return error.UnknownCard;
                    }
                    retries += 1;
                }
            }
            // verify is SD or MMC
        } else {
            if ((cmd8_resp.ocr & 0xfff) == 0x1aa) {
                self._card_type = try self.initiate_intitialization_process(1);
                if (self._card_type) |card_type| {
                    log.info("Found card with type: {s}", .{@tagName(card_type)});
                } else {
                    return error.UnknownCard;
                }
            } else {
                log.warn("Unknown card type, CMD8 R1({x}) R7({x})", .{ cmd8_resp.r1, cmd8_resp.ocr });
                return error.UnknownCard;
            }
        }

        // const cmd0 = self._mmc.build_command(0, 0);
        // self._mmc.transmit_blocking(cmd0, null);
    }
});
