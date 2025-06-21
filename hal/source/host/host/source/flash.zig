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

pub const Flash = struct {
    pub const BlockSize = 1;
    pub fn init() void {}

    pub fn create() Flash {
        return .{};
    }

    pub fn read(self: Flash, address: u32, buffer: []u8) void {
        _ = buffer;
        _ = self;
        std.debug.print("Reading from flash at address {x}\n", .{address});
    }

    pub fn write(self: Flash, address: u32, data: []const u8) void {
        _ = data;
        _ = self;
        std.debug.print("Writing to flash at address {x}\n", .{address});
    }

    pub fn erase(self: Flash, address: u32) void {
        _ = self;
        std.debug.print("Erasing flash at address {x}\n", .{address});
    }

    pub fn get_number_of_blocks(self: Flash) u32 {
        _ = self;
        return 1024;
    }
};
