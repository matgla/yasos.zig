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

pub fn Uart(comptime index: usize, comptime pins: Pins, comptime uart: anytype) type {
    const UartImplementation = uart(index, pins);
    return struct {
        const Self = @This();
        impl: UartImplementation,

        pub fn create() Self {
            return Self{
                .impl = UartImplementation{},
            };
        }

        pub fn init(self: Self, config: Config) InitializeError!void {
            try self.impl.init(config);
        }

        pub const Writer = std.io.Writer(Self, WriteError, write_some);

        pub fn writer(self: Self) Writer {
            return Writer{ .context = self };
        }

        pub fn write_some(self: Self, buffer: []const u8) WriteError!usize {
            return self.impl.write(buffer) catch return WriteError.WriteFailure;
        }

        pub fn write_some_opaque(self: *const anyopaque, buffer: []const u8) usize {
            const realSelf: *const Self = @ptrCast(@alignCast(self));
            return realSelf.*.impl.write(buffer) catch {
                return 0;
            };
        }
    };
}

pub const WriteError = error{
    WriteFailure,
};

pub const InitializeError = error{};

pub const Pins = struct {
    tx: ?u32 = null,
    rx: ?u32 = null,
};

pub const Config = struct {
    baudrate: ?u32,
};
