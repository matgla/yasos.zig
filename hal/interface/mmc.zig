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
        const Self = @This();
        impl: MMCImplementation,

        pub fn create(pins: Pins, config: Config) Self {
            return Self{
                .impl = MMCImplementation.create(pins, config),
            };
        }

        pub fn init(self: *Self, comptime config: Config) InitializeError!void {
            try self.impl.init(config);
        }
    };
}

pub const InitializeError = error{};

pub const Pins = struct {
    clk: u32,
    cmd: u32,
    d0: u32,
};

pub const Mode = enum {
    SPI,
    SDIO,
    MMC,
};

pub const Config = struct {
    bus_width: u8 = 4,
    clock_speed: u32 = 50 * 1000 * 1000,
    timeout_ms: u32 = 1000,
    use_dma: bool = true,
    mode: Mode,
};
