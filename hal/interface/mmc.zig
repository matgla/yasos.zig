//
// mmc.zig
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

const std = @import("std");

pub fn Mmc(comptime MmcType: anytype) type {
    const MMCImplementation = MmcType;
    return struct {
        pub const Pins = PinsConfig;
        pub const Config = MmcConfig;
        const Self = @This();
        impl: MMCImplementation,

        pub fn create(config: Config) Self {
            return Self{
                .impl = MMCImplementation.create(config),
            };
        }

        pub fn init(self: *Self) anyerror!void {
            try self.impl.init();
        }

        pub fn get_config(self: Self) MmcConfig {
            return self.impl.get_config();
        }

        pub fn build_command(self: Self, command: u6, argument: u32) [6]u8 {
            return self.impl.build_command(command, argument);
        }

        pub fn transmit_blocking(self: Self, src: []const u8, dest: ?[]u8) void {
            return self.impl.transmit_blocking(src, dest);
        }

        pub fn chip_select(self: Self, select: bool) void {
            return self.impl.chip_select(select);
        }
    };
}

pub const InitializeError = error{};

pub const PinsConfig = struct {
    clk: u32,
    cmd: u32,
    d0: u32,
};

pub const Mode = enum {
    SPI,
    SDIO,
    MMC,
};

pub const MmcConfig = struct {
    bus_width: u8 = 4,
    clock_speed: u32 = 50 * 1000 * 1000,
    timeout_ms: u32 = 1000,
    use_dma: bool = true,
    mode: Mode,
    pins: PinsConfig,
};
