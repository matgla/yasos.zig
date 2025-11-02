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
    _size: u32,

    pub fn init(allocator: std.mem.Allocator, device_file: IFile, offset: c.off_t) !FileSystemHeader {
        var marker: [8]u8 = undefined;
        var df = device_file;

        _ = try df.interface.seek(offset, c.SEEK_SET);
        _ = df.interface.read(marker[0..]);
        if (!std.mem.eql(u8, marker[0..], "-rom1fs-")) {
            return kernel.errno.ErrnoSet.InvalidArgument;
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
        var reader = try FileReader.init(df, offset);
        const filesize = try reader.read(u32, 8);
        return .{
            ._allocator = allocator,
            ._reader = reader,
            ._device_file = df,
            ._mapped_memory = mapped_memory_address,
            ._offset = offset,
            ._size = filesize,
        };
    }

    pub fn size(self: *const FileSystemHeader) u32 {
        return self._size;
    }

    fn read(self: *FileSystemHeader, comptime T: type) T {
        var buffer: [@sizeOf(T)]u8 = undefined;
        _ = self._device_file.interface.read(buffer[0..]);
        return std.mem.bigToNative(T, std.mem.bytesToValue(T, buffer[0..]));
    }

    // genromfs sets checksum field as 0 before calculation and returns -sum as a result
    // if result is equal to 0, then checksum is correct
    pub fn validate_checksum(self: *FileSystemHeader) !bool {
        const current = self._device_file.interface.tell();
        _ = try self._device_file.interface.seek(0, c.SEEK_SET);
        const dsize = self._device_file.interface.size();
        const length = @min(dsize, 512);
        var i: u32 = 0;
        var checksum_value: u32 = 0;
        while (i < length) {
            checksum_value +%= self.read(u32);
            i += 4;
        }

        _ = try self._device_file.interface.seek(current, c.SEEK_SET);
        return checksum_value == 0;
    }

    pub fn name(self: *FileSystemHeader) ?kernel.fs.FileName {
        const n = self._reader.read_string(self._allocator, 16) catch return null;
        return kernel.fs.FileName.init(n, self._allocator);
    }

    pub fn create_file_header_with_offset(self: *FileSystemHeader, offset: c.off_t) !FileHeader {
        return try FileHeader.init(self._device_file, self._reader.get_offset() + offset, self._offset, self._mapped_memory, self._allocator);
    }

    pub fn first_file_header(self: *FileSystemHeader) !?FileHeader {
        return try self.create_file_header_with_offset(self._reader.get_data_offset());
    }
};

test "FileSystemHeader.ShouldParseFilesystemHeader" {
    const RomfsDeviceStub = @import("tests/romfs_device_stub.zig").RomfsDeviceStub;
    var device = try RomfsDeviceStub.InstanceType.init(std.testing.allocator, "source/fs/romfs/tests/test.romfs", null);
    var idevice = device.interface.create();
    try idevice.interface.load();
    var device_node = try idevice.interface.node();
    defer device_node.delete();
    try std.testing.expect(device_node.filetype() == kernel.fs.FileType.File);
    var fs = try FileSystemHeader.init(std.testing.allocator, device_node.as_file().?, 0);
    try std.testing.expectEqual(fs.size(), 1040);
    try std.testing.expect(try fs.validate_checksum());
    {
        const name = fs.name().?;
        defer name.deinit();
        try std.testing.expectEqualStrings("ROMFS_TEST", name.get_name());
    }
    {
        var fh = try fs.first_file_header();
        defer if (fh) |*file| file.deinit();
        try std.testing.expect(fh != null);
        const name = fh.?.name();
        try std.testing.expectEqualStrings(name, ".");
        try std.testing.expectEqual(fh.?.filetype(), FileType.Directory);

        {
            var next_fh = try fh.?.next();
            try std.testing.expect(next_fh != null);
            defer next_fh.?.deinit();
            const next_name = next_fh.?.name();
            try std.testing.expectEqualStrings(next_name, "..");
            {
                var fh2 = try next_fh.?.next();
                defer fh2.?.deinit();
                var fh3 = try fh2.?.next();
                defer fh3.?.deinit();
                var fh4 = try fh3.?.next();
                try std.testing.expect(fh4 != null);
                if (fh4) |*file| {
                    defer file.deinit();
                    const nextnext_name = file.name();
                    try std.testing.expectEqualStrings(nextnext_name, "file.txt");
                    try std.testing.expect(try file.validate_checksum());
                    var data: [20]u8 = undefined;
                    try file.read_bytes(data[0..20], 0);
                    try std.testing.expectEqualStrings(data[0..], "THis is testing file");
                    try std.testing.expectEqual(file.filetype(), FileType.File);
                }
            }
        }
    }
}

test "FileSystemHeader.ShouldRejectInvalidFilesystemHeader" {
    const RomfsDeviceStub = @import("tests/romfs_device_stub.zig").RomfsDeviceStub;
    var device = try RomfsDeviceStub.InstanceType.init(std.testing.allocator, "source/fs/romfs/file_system_header.zig", null);
    var idevice = device.interface.create();
    try idevice.interface.load();
    var device_node = try idevice.interface.node();
    defer device_node.delete();
    try std.testing.expect(device_node.filetype() == kernel.fs.FileType.File);
    try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, FileSystemHeader.init(std.testing.allocator, device_node.as_file().?, 0));
}
