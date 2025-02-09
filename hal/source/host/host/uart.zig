//
// uart.zig
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

const interface = @import("hal_interface");

pub fn Uart(comptime index: usize, comptime _: interface.uart.Pins) type {
    return struct {
        const Self = @This();
        const fd = index;

        pub fn init(_: Self, _: interface.uart.Config) interface.uart.InitializeError!void {}

        pub fn write(_: Self, data: []const u8) !usize {
            _ = try std.posix.write(fd, data);
            return data.len;
        }
    };
}
