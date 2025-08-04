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

pub const MmcDriver = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();
    _mmc: hal.mmc.Mmc,
    _name: []const u8,

    pub fn create(mmc: hal.mmc.Mmc, driver_name: []const u8) MmcDriver {
        return MmcDriver.init(.{
            ._mmc = mmc,
            ._name = driver_name,
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
                try self.initialize_spi_mmc();
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

    fn read_response_r3(self: *const Self) u8 {
        const wait: [4]u8 = [_]u8{0xff} ** 4;
        var resp: [4]u8 = [_]u8{0xff} ** 4;
        self._mmc.transmit_blocking(wait[0..], resp[0..]);
        return std.mem.bitToNative(std.mem.bytesAsValue(u32, resp));
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

    fn initialize_spi_mmc(self: *Self) error{CardInitializationFailure}!void {
        log.info("initializing MMC using SPI mode", .{});
        self.reset() catch return error.CardInitializationFailure;

        // const cmd0 = self._mmc.build_command(0, 0);
        // self._mmc.transmit_blocking(cmd0, null);
    }
});
