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

const kernel = @import("kernel");
const FileType = kernel.fs.FileType;
const IFile = kernel.fs.IFile;
const FileMemoryMapAttributes = kernel.fs.FileMemoryMapAttributes;
const IoctlCommonCommands = kernel.fs.IoctlCommonCommands;

const c = @import("libc_imports").c;

pub const FileSystemHeader = struct {
    _allocator: std.mem.Allocator,
    _reader: FileReader,
    _device_file: IFile,
    _mapped_memory: ?*const anyopaque,
    _offset: c.off_t,

    pub fn init(allocator: std.mem.Allocator, device_file: IFile, offset: c.off_t) ?FileSystemHeader {
        var marker: [8]u8 = undefined;
        var df = device_file;

        _ = df.interface.seek(offset, c.SEEK_SET);
        _ = df.interface.read(marker[0..]);
        if (!std.mem.eql(u8, marker[0..], "-rom1fs-")) {
            return null;
        }

        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = df.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
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

    pub fn size(self: *FileSystemHeader) u32 {
        return self._reader.read(u32, 8);
    }

    pub fn checksum(self: FileSystemHeader) u32 {
        return self._reader.read(u32, 12);
    }

    fn read(self: *FileSystemHeader, comptime T: type) T {
        var buffer: [@sizeOf(T)]u8 = undefined;
        _ = self._device_file.interface.read(buffer[0..]);
        return std.mem.bigToNative(T, std.mem.bytesToValue(T, buffer[0..]));
    }

    // genromfs sets checksum field as 0 before calculation and returns -sum as a result
    // if result is equal to 0, then checksum is correct
    pub fn validate_checksum(self: *FileSystemHeader) bool {
        const current = self._device_file.interface.tell();
        _ = self._device_file.interface.seek(0, c.SEEK_SET);
        const length = @min(self._device_file.interface.size(), 512);
        var i: u32 = 0;
        var checksum_value: u32 = 0;
        while (i < length) {
            checksum_value +%= self.read(u32);
            i += 4;
        }

        _ = self._device_file.interface.seek(current, c.SEEK_SET);
        return checksum_value == 0;
    }

    pub fn name(self: *FileSystemHeader) ?kernel.fs.FileName {
        const n = self._reader.read_string(self._allocator, 16) catch return null;
        return kernel.fs.FileName.init(n, self._allocator);
    }

    pub fn create_file_header_with_offset(self: *FileSystemHeader, offset: c.off_t) FileHeader {
        return FileHeader.init(self._device_file, self._reader.get_offset() + offset, self._offset, self._mapped_memory, self._allocator);
    }

    pub fn first_file_header(self: *FileSystemHeader) ?FileHeader {
        return self.create_file_header_with_offset(self._reader.get_data_offset());
    }
};

test "FileSystemHeader.ShouldParseFilesystemHeader" {
    const RomfsDeviceStub = @import("tests/romfs_device_stub.zig").RomfsDeviceStub;
    var device = RomfsDeviceStub.InstanceType.init(&std.testing.allocator, "source/fs/romfs/tests/test.romfs");
    var idevice = device.interface.create();
    try idevice.interface.load();
    var device_file = idevice.interface.ifile(std.testing.allocator);
    try std.testing.expect(device_file != null);
    defer device_file.?.interface.delete();
    var maybe_fs = FileSystemHeader.init(std.testing.allocator, device_file.?, 0);
    try std.testing.expect(maybe_fs != null);
    if (maybe_fs) |*fs| {
        try std.testing.expectEqual(fs.size(), 1040);
        try std.testing.expect(fs.validate_checksum());
        {
            const name = fs.name().?;
            defer name.deinit();
            try std.testing.expectEqualStrings("ROMFS_TEST", name.get_name());
        }
        {
            var fh = fs.first_file_header();
            defer if (fh) |*file| file.deinit();
            try std.testing.expect(fh != null);
            var name = fh.?.name(std.testing.allocator);
            defer name.deinit();
            try std.testing.expectEqualStrings(name.get_name(), ".");
            try std.testing.expectEqual(fh.?.filetype(), FileType.Directory);

            {
                var next_fh = fh.?.next();
                try std.testing.expect(next_fh != null);
                var next_name = next_fh.?.name(std.testing.allocator);
                defer next_name.deinit();
                try std.testing.expectEqualStrings(next_name.get_name(), "..");
                {
                    var fh2 = next_fh.?.next();
                    var fh3 = fh2.?.next();
                    var fh4 = fh3.?.next();
                    try std.testing.expect(fh4 != null);
                    if (fh4) |*file| {
                        var nextnext_name = file.name(std.testing.allocator);
                        defer nextnext_name.deinit();
                        try std.testing.expectEqualStrings(nextnext_name.get_name(), "file.txt");
                        try std.testing.expect(file.validate_checksum());
                        var data: [20]u8 = undefined;
                        file.read_bytes(data[0..20], 0);
                        try std.testing.expectEqualStrings(data[0..], "THis is testing file");
                        try std.testing.expectEqual(file.filetype(), FileType.File);
                    }
                }
            }
        }
    }
}
