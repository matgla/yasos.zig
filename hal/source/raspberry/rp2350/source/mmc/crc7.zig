//
// crc7.zig
//
// Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

/// The last byte of an SD command: CRC-7/MMC over the first five, then the end
/// bit. Bit by bit, because this runs under the whole filesystem on a process's
/// stack, and `std.hash.crc` takes a 296-byte frame for its table.
pub fn command_crc_byte(bytes: []const u8) u8 {
    var crc: u8 = 0;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = if ((crc & 0x80) != 0) (crc << 1) ^ (0x09 << 1) else crc << 1;
        }
    }
    return crc | 1;
}

comptime {
    // The two every SD specification prints.
    std.debug.assert(command_crc_byte(&.{ 0x40, 0, 0, 0, 0 }) == 0x95);
    std.debug.assert(command_crc_byte(&.{ 0x48, 0, 0, 0x01, 0xAA }) == 0x87);
}
