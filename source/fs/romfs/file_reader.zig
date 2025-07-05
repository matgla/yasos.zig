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

const IFile = @import("../../kernel/fs/ifile.zig").IFile;

const c = @import("../../libc_imports.zig").c;

pub const FileReader = struct {
    _device_file: IFile,
    _offset: u32,
    _data_offset: u32,

    pub fn init(device_file: IFile, offset: u32) FileReader {
        var data_offset_value: u32 = 32;
        var buffer: [16]u8 = undefined;
        var df = device_file;
        _ = df.seek(offset + 16, c.SEEK_SET);
        _ = df.read(buffer[0..]);
        while (std.mem.lastIndexOfScalar(u8, buffer[0..], 0) == null) {
            data_offset_value += 16;
            _ = df.read(buffer[0..]);
        }

        return .{
            ._device_file = df,
            ._offset = offset,
            ._data_offset = data_offset_value,
        };
    }

    pub fn get_offset(self: *const FileReader) u32 {
        return self._offset;
    }

    pub fn get_data_offset(self: *const FileReader) u32 {
        return self._data_offset;
    }

    pub fn read(self: *FileReader, comptime T: type, offset: u32) T {
        var buffer: [@sizeOf(T)]u8 = undefined;
        _ = self._device_file.seek(self._offset + offset, c.SEEK_SET);
        _ = self._device_file.read(buffer[0..]);
        return std.mem.bigToNative(T, std.mem.bytesToValue(T, buffer[0..]));
    }

    pub fn read_string(self: *FileReader, allocator: std.mem.Allocator, offset: u32) ![]u8 {
        _ = self._device_file.seek(self._offset + offset, c.SEEK_SET);
        var name_buffer: []u8 = try allocator.alloc(u8, 16);

        _ = self._device_file.read(name_buffer[0..]);
        while (std.mem.lastIndexOfScalar(u8, name_buffer, 0) == null) {
            name_buffer = try allocator.realloc(name_buffer, name_buffer.len + 16);
            _ = self._device_file.read(name_buffer[name_buffer.len - 16 ..]);
        }

        return name_buffer;
    }

    pub fn read_bytes(self: *FileReader, buffer: []u8, offset: u32) void {
        _ = self._device_file.seek(self._offset + offset, c.SEEK_SET);
        _ = self._device_file.read(buffer[0..]);
    }
};

const RomfsDeviceStub = @import("tests/romfs_device_stub.zig").RomfsDeviceStub;
test "RomFs FileReader should read data correctly" {
    var romfs_device = RomfsDeviceStub.create(&std.testing.allocator, "source/fs/romfs/tests/test.romfs");
    defer romfs_device.destroy();
    const idriver = romfs_device.interface();
    _ = idriver;
    // try idriver.load();
    // const idevicefile = idriver.ifile();
    // _ = idevicefile;
}
