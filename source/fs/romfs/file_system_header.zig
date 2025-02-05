//
// file_system_header.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
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

const FileSystemHeader = struct {
    memory: []const u8,

    pub fn init(memory: []const u8) ?FileSystemHeader {
        const marker = memory[0..8];
        if (!std.mem.eql(u8, marker, "-rom1fs-")) {
            return null;
        }
        return .{
            .memory = memory,
        };
    }

    inline fn read(comptime T: type, buffer: []const u8) T {
        return std.mem.bigToNative(T, std.mem.bytesToValue(T, buffer));
    }

    pub fn size(self: FileSystemHeader) u32 {
        return FileSystemHeader.read(u32, self.memory[8..12]);
    }

    pub fn checksum(self: FileSystemHeader) u32 {
        return FileSystemHeader.read(u32, self.memory[12..16]);
    }

    pub fn calculate_checksum(self: FileSystemHeader) u32 {
        const length = @min(self.memory.len, 512);
        var i: u32 = 0;
        var checksum_value: u32 = 0;
        while (i < length) {
            const d = FileSystemHeader.read(i32, self.memory[i .. i + 4]);
            checksum_value +%= FileSystemHeader.read(u32, self.memory[i .. i + 4]);
            std.debug.print("{d} 0x{x} | 0x{x}\n", .{ i, checksum_value, d });
            i += 4;
        }
        return checksum_value;
    }
};

test "Parse filesystem header" {
    const test_data = @embedFile("test_img.romfs");
    const maybe_fs = FileSystemHeader.init(test_data);
    try std.testing.expect(maybe_fs != null);
    if (maybe_fs) |fs| {
        try std.testing.expectEqual(fs.size(), 376752);
        try std.testing.expectEqual(fs.checksum(), fs.calculate_checksum());
    }
}
