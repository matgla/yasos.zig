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

pub const MBRPartitionEntry = packed struct {
    boot_indicator: u8,
    start_chs: u24,
    partition_type: u8,
    end_chs: u24,
    start_lba: u32,
    size_in_sectors: u32,
};

pub const MBR = struct {
    partitions: [4]MBRPartitionEntry,
    _signature: u16,

    pub fn create(buffer: []const u8) MBR {
        var mbr: MBR = undefined;
        for (0..4) |i| {
            mbr.partitions[i] = std.mem.bytesToValue(MBRPartitionEntry, &buffer[446 + i * @sizeOf(MBRPartitionEntry)]);
        }
        mbr._signature = std.mem.bytesToValue(u16, buffer[510..512]);
        return mbr;
    }

    pub fn is_valid(self: MBR) bool {
        return self._signature == 0xAA55;
    }
};
