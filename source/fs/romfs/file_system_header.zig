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
const FileReader = @import("file_reader.zig").FileReader;

const FileType = @import("../../kernel/fs/ifile.zig").FileType;

const IFile = @import("../../kernel/fs/ifile.zig").IFile;

const c = @import("../../libc_imports.zig").c;

const FileMemoryMapAttributes = @import("../../kernel/fs/ifile.zig").FileMemoryMapAttributes;
const IoctlCommonCommands = @import("../../kernel/fs/ifile.zig").IoctlCommonCommands;

pub const FileSystemHeader = struct {
    _allocator: std.mem.Allocator,
    _reader: FileReader,
    _device_file: IFile,
    _mapped_memory: ?*const anyopaque,
    _offset: c.off_t,

    pub fn init(allocator: std.mem.Allocator, device_file: IFile, offset: c.off_t) ?FileSystemHeader {
        var marker: [8]u8 = undefined;
        var df = device_file;

        _ = df.seek(offset, c.SEEK_SET);
        _ = df.read(marker[0..]);
        if (!std.mem.eql(u8, marker[0..], "-rom1fs-")) {
            return null;
        }

        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = df.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        var mapped_memory_address: ?*const anyopaque = null;
        if (attr.mapped_address_r) |address| {
            mapped_memory_address = @ptrFromInt(@intFromPtr(address) + @as(usize, @intCast(offset)));
        }

        return .{
            ._allocator = allocator,
            ._reader = FileReader.init(df, offset),
            ._device_file = df,
            ._mapped_memory = mapped_memory_address,
            ._offset = offset,
        };
    }

    pub fn deinit(self: FileSystemHeader) void {
        _ = self;
    }

    fn get_name(allocator: std.mem.Allocator, file: IFile, offset: u32) ![]u8 {
        _ = file.seek(offset, c.SEEK_SET);
        var name_buffer: []u8 = try allocator.alloc(u8, 16);

        _ = file.read(name_buffer[0..]);
        while (std.mem.lastIndexOfScalar(u8, name_buffer, 0) == null) {
            name_buffer = try allocator.realloc(name_buffer, name_buffer.len + 16);
            _ = file.read(name_buffer[name_buffer.len - 16 ..]);
        }

        return name_buffer;
    }

    pub fn size(self: FileSystemHeader) u32 {
        return self._reader.read(u32, 8);
    }

    pub fn checksum(self: FileSystemHeader) u32 {
        return self._reader.read(u32, 12);
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

    pub fn name(self: FileSystemHeader) ?[]const u8 {
        _ = self;
        return null;
    }

    pub fn create_file_header_with_offset(self: FileSystemHeader, offset: c.off_t) FileHeader {
        return FileHeader.init(self._device_file, self._reader.get_offset() + offset, self._offset, self._mapped_memory, self._allocator);
    }

    pub fn first_file_header(self: FileSystemHeader) ?FileHeader {
        return self.create_file_header_with_offset(self._reader.get_data_offset());
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
