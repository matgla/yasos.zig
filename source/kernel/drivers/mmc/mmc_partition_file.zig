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

const c = @import("libc_imports").c;

const hal = @import("hal");
const interface = @import("interface");

const kernel = @import("../../kernel.zig");

pub const MmcPartitionFile =
    interface.DeriveFromBase(kernel.fs.IFile, struct {
        const Self = @This();

        /// VTable for IFile interface
        _allocator: std.mem.Allocator,
        _name: []const u8,
        _dev: *kernel.fs.IFile,
        _start_lba: u32,
        _size_in_sectors: u32,
        _current_position: c.off_t,

        pub fn create(allocator: std.mem.Allocator, filename: []const u8, dev: *kernel.fs.IFile, start_lba: u32, size_in_sectors: u32) MmcPartitionFile {
            return MmcPartitionFile.init(.{
                ._allocator = allocator,
                ._name = filename,
                ._dev = dev,
                ._start_lba = start_lba,
                ._size_in_sectors = size_in_sectors,
                ._current_position = @as(c.off_t, @intCast(start_lba)) << 9,
            });
        }

        pub fn read(self: *Self, buf: []u8) isize {
            _ = self._dev.interface.seek(self._current_position, c.SEEK_SET);
            const readed = self._dev.interface.read(buf);
            self._current_position += readed;
            return readed;
        }

        pub fn write(self: *Self, buf: []const u8) isize {
            _ = self._dev.interface.seek(self._current_position, c.SEEK_SET);
            const written = self._dev.interface.write(buf);
            self._current_position += written;
            return written;
        }

        pub fn seek(self: *Self, offset: c.off_t, base: i32) c.off_t {
            if (offset > (self._start_lba + self._size_in_sectors) << 9) {
                kernel.log.err("Seek offset {d} is out of bounds for MMC partition file", .{offset});
                return -1;
            }
            if (@as(c.off_t, @intCast(self._start_lba)) + (offset >> 9) < @as(c.off_t, @intCast(self._start_lba))) {
                kernel.log.err("Seek offset {d} is before the start of MMC partition file", .{offset});
                return -1;
            }
            const seek_offset = (@as(c.off_t, @intCast(self._start_lba)) << 9) + offset;
            self._current_position = self._dev.interface.seek(seek_offset, base);
            return self._current_position;
        }

        pub fn close(self: *Self) void {
            _ = self;
        }

        pub fn sync(self: *Self) i32 {
            _ = self;
            return 0;
        }

        pub fn tell(self: *Self) c.off_t {
            _ = self;
            return 0;
        }

        pub fn size(self: *Self) isize {
            return @intCast(self._size_in_sectors << 9);
        }

        pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
            _ = allocator;
            return kernel.fs.FileName.init(self._name, null);
        }

        pub fn ioctl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
            _ = self;
            _ = cmd;
            _ = arg;
            return 0;
        }

        pub fn fcntl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
            _ = self;
            _ = cmd;
            _ = arg;
            return 0;
        }

        pub fn stat(self: *Self, data: *c.struct_stat) void {
            _ = self;
            _ = data;
        }

        pub fn filetype(self: *Self) kernel.fs.FileType {
            _ = self;
            return kernel.fs.FileType.BlockDevice;
        }

        pub fn delete(self: *Self) void {
            _ = self.close();
        }
    });
