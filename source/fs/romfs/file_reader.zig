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
const dev_lock = kernel.driver.dev_lock;
const IFile = kernel.fs.IFile;

const c = @import("libc_imports").c;

pub const FileReader = struct {
    _device_file: IFile,
    _offset: u64,
    _data_offset: u64,

    /// Construct over an entry whose data offset the caller already knows.
    ///
    /// `init` below finds the data offset by scanning the name, which costs a
    /// seek and at least one read. `FileHeader.init` reads the fixed header and
    /// the name in one go and so knows the answer already; this lets it say so
    /// instead of paying for the scan a second time.
    pub fn init_at(device_file: IFile, offset: u64, data_offset: u64) FileReader {
        return .{
            ._device_file = device_file,
            ._offset = offset,
            ._data_offset = data_offset,
        };
    }

    pub fn init(device_file: IFile, offset: u64) !FileReader {
        dev_lock.acquire();
        defer dev_lock.release();
        var data_offset_value: u64 = 32;
        var buffer: [16]u8 = undefined;
        var df = device_file;
        kernel.perf.romfs_read();
        _ = try df.interface.seek(@intCast(offset + 16), c.SEEK_SET);
        _ = df.interface.read(buffer[0..]);
        while (std.mem.lastIndexOfScalar(u8, buffer[0..], 0) == null) {
            data_offset_value += 16;
            kernel.perf.romfs_read();
            _ = df.interface.read(buffer[0..]);
        }

        return .{
            ._device_file = df,
            ._offset = offset,
            ._data_offset = data_offset_value,
        };
    }

    pub fn get_offset(self: *const FileReader) c.off_t {
        return @intCast(self._offset);
    }

    pub fn get_data_offset(self: *const FileReader) c.off_t {
        return @intCast(self._data_offset);
    }

    pub fn read(self: *FileReader, comptime T: type, offset: u64) !T {
        dev_lock.acquire();
        defer dev_lock.release();
        var buffer: [@sizeOf(T)]u8 = undefined;
        kernel.perf.romfs_read();
        _ = try self._device_file.interface.seek(@intCast(self._offset + offset), c.SEEK_SET);
        _ = self._device_file.interface.read(buffer[0..]);
        return std.mem.bigToNative(T, std.mem.bytesToValue(T, buffer[0..]));
    }

    pub fn read_string(self: *FileReader, allocator: std.mem.Allocator, offset: c.off_t) ![]u8 {
        // The whole loop, not just the first read: it keeps reading forward
        // from one seek until it finds the terminator, so a device
        // repositioned partway through returns the tail of somebody else's
        // file as the rest of this name.
        dev_lock.acquire();
        defer dev_lock.release();
        _ = try self._device_file.interface.seek(@as(i64, @intCast(self._offset)) + @as(i64, @intCast(offset)), c.SEEK_SET);
        var name_buffer: [16]u8 = undefined;
        var output_buffer: []u8 = &.{};
        var finished: bool = false;
        @memset(name_buffer[0..], 0);
        while (!finished) {
            kernel.perf.romfs_read();
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
        dev_lock.acquire();
        defer dev_lock.release();
        _ = try self._device_file.interface.seek(@as(i64, @intCast(self._offset)) + @as(i64, @intCast(offset)), c.SEEK_SET);
        _ = self._device_file.interface.read(buffer[0..]);
    }
};
