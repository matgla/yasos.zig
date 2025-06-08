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

const FileHeader = @import("file_header.zig").FileHeader;
const FileType = @import("../../kernel/fs/ifile.zig").FileType;

pub const FileSystemHeader = struct {
    memory: []const u8,

    pub fn get_romfs_size(memory: []const u8) ?usize {
        if (memory.len < 12) {
            return null;
        }
        const marker = memory[0..8];
        if (!std.mem.eql(u8, marker, "-rom1fs-")) {
            return null;
        }
        return std.mem.bigToNative(u32, std.mem.bytesToValue(u32, memory[8..12]));
    }

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

    // genromfs sets checksum field as 0 before calculation and returns -sum as a result
    // if result is equal to 0, then checksum is correct
    pub fn validate_checksum(self: FileSystemHeader) bool {
        const length = @min(self.memory.len, 512);
        var i: u32 = 0;
        var checksum_value: u32 = 0;
        while (i < length) {
            checksum_value +%= FileSystemHeader.read(u32, self.memory[i .. i + 4]);
            i += 4;
        }
        return checksum_value == 0;
    }

    pub fn name(self: FileSystemHeader) []const u8 {
        return std.mem.sliceTo(self.memory[16..], 0);
    }

    pub fn first_file_header(self: FileSystemHeader) ?FileHeader {
        const file_header_index = 16 + self.name().len;
        const remainder = file_header_index % 16;
        const padded_index = if (remainder == 0) file_header_index else (file_header_index + (16 - remainder));
        return FileHeader.init(self.memory, padded_index);
    }
};

test "Parse filesystem header" {
    const test_data = @embedFile("test.romfs");
    const maybe_fs = FileSystemHeader.init(test_data);
    try std.testing.expect(maybe_fs != null);
    if (maybe_fs) |fs| {
        try std.testing.expectEqual(fs.size(), 1040);
        try std.testing.expect(fs.validate_checksum());
        try std.testing.expectEqualStrings("ROMFS_TEST", fs.name());
        try std.testing.expectEqualStrings(fs.first_file_header().name(), ".");
        try std.testing.expectEqual(fs.first_file_header().filetype(), FileType.Directory);

        try std.testing.expectEqualStrings(fs.first_file_header().next().?.name(), "..");
        const maybe_file = fs.first_file_header().next().?.next().?.next().?.next();
        if (maybe_file) |file| {
            try std.testing.expectEqualStrings(file.name(), "file.txt");
            try std.testing.expect(file.validate_checksum());
            try std.testing.expectEqualStrings(file.data()[0..20], "THis is testing file");
            try std.testing.expectEqual(file.filetype(), FileType.File);
        }
    }
}
