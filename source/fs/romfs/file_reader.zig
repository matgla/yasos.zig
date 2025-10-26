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

const kernel = @import("kernel");
const IFile = kernel.fs.IFile;

const c = @import("libc_imports").c;

pub const FileReader = struct {
    _device_file: IFile,
    _offset: c.off_t,
    _data_offset: c.off_t,

    pub fn init(device_file: IFile, offset: c.off_t) !FileReader {
        var data_offset_value: c.off_t = 32;
        var buffer: [16]u8 = undefined;
        var df = device_file;
        _ = try df.interface.seek(offset + 16, c.SEEK_SET);
        _ = df.interface.read(buffer[0..]);
        while (std.mem.lastIndexOfScalar(u8, buffer[0..], 0) == null) {
            data_offset_value += 16;
            _ = df.interface.read(buffer[0..]);
        }

        return .{
            ._device_file = df,
            ._offset = offset,
            ._data_offset = data_offset_value,
        };
    }

    pub fn get_offset(self: *const FileReader) c.off_t {
        return self._offset;
    }

    pub fn get_data_offset(self: *const FileReader) c.off_t {
        return self._data_offset;
    }

    pub fn read(self: *FileReader, comptime T: type, offset: c.off_t) !T {
        var buffer: [@sizeOf(T)]u8 = undefined;
        _ = try self._device_file.interface.seek(self._offset + offset, c.SEEK_SET);
        _ = self._device_file.interface.read(buffer[0..]);
        return std.mem.bigToNative(T, std.mem.bytesToValue(T, buffer[0..]));
    }

    pub fn read_string(self: *FileReader, allocator: std.mem.Allocator, offset: c.off_t) ![]u8 {
        _ = try self._device_file.interface.seek(self._offset + offset, c.SEEK_SET);
        var name_buffer: [16]u8 = undefined;
        var output_buffer: []u8 = &.{};
        var finished: bool = false;
        @memset(name_buffer[0..], 0);
        while (!finished) {
            _ = self._device_file.interface.read(name_buffer[0..]);
            const null_index = std.mem.indexOfScalar(u8, name_buffer[0..], 0);
            if (null_index) |end| {
                finished = true;
                output_buffer = try allocator.realloc(output_buffer, (output_buffer.len + end));
                @memcpy(output_buffer[output_buffer.len - end ..], name_buffer[0..end]);
            } else {
                output_buffer = try allocator.realloc(output_buffer, (output_buffer.len + name_buffer.len));
                @memcpy(output_buffer[output_buffer.len - name_buffer.len ..], name_buffer[0..]);
            }
        }

        return output_buffer;
    }

    pub fn read_bytes(self: *FileReader, buffer: []u8, offset: c.off_t) !void {
        _ = try self._device_file.interface.seek(self._offset + offset, c.SEEK_SET);
        _ = self._device_file.interface.read(buffer[0..]);
    }
};
