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

const interface = @import("interface");

const kernel = @import("../kernel.zig");

pub fn BufferedFile(comptime BufferSize: usize) type {
    const Internal = struct {
        const BufferedFileInst = interface.DeriveFromBase(kernel.fs.ReadOnlyFile, struct {
            const Self = @This();
            base: kernel.fs.ReadOnlyFile,
            _position: usize,
            _buffer: [BufferSize]u8,
            _name: []const u8,
            _end: usize,

            pub fn create(filename: []const u8) BufferedFileInst {
                const file = BufferedFileInst.init(.{
                    .base = kernel.fs.ReadOnlyFile.init(.{}),
                    ._position = 0,
                    ._buffer = .{0} ** BufferSize,
                    ._name = filename,
                    ._end = 0,
                });
                return file;
            }

            pub fn read(self: *Self, buffer: []u8) isize {
                const file_len = self._end;
                if (self._position >= file_len) {
                    return 0;
                }
                const read_length = @min(self._end - self._position, self._end);
                @memcpy(buffer[0..read_length], self._buffer[self._position .. self._position + read_length]);
                self._position += read_length;
                return @intCast(read_length);
            }

            pub fn seek(self: *Self, offset: c.off_t, whence: i32) c.off_t {
                switch (whence) {
                    c.SEEK_SET => {
                        if (offset < 0) {
                            return -1;
                        }
                        self._position = @as(usize, @intCast(offset));
                        return @intCast(self._position);
                    },
                    c.SEEK_CUR => {
                        const new_position = @as(c.off_t, @intCast(self._position)) + offset;
                        if (new_position < 0) {
                            return -1;
                        }
                        self._position = @as(usize, @intCast(new_position));
                    },
                    c.SEEK_END => {
                        self._position = self._end + @as(usize, @intCast(offset));
                    },
                    else => {
                        return -1;
                    },
                }
                return 0;
            }

            pub fn tell(self: *Self) c.off_t {
                return @intCast(self._position);
            }

            pub fn name(self: *const Self) []const u8 {
                return self._name;
            }

            pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
                _ = self;
                _ = cmd;
                _ = data;
                return 0;
            }

            pub fn fcntl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
                _ = self;
                _ = cmd;
                _ = data;
                return 0;
            }

            pub fn stat(self: *Self, buf: *c.struct_stat) void {
                _ = self;
                buf.st_dev = 0;
                buf.st_ino = 0;
                buf.st_mode = c.S_IFREG;
                buf.st_nlink = 0;
                buf.st_uid = 0;
                buf.st_gid = 0;
                buf.st_rdev = 0;
                buf.st_size = 0;
                buf.st_blksize = 1;
                buf.st_blocks = 1;
            }

            pub fn filetype(self: *const Self) kernel.fs.FileType {
                _ = self;
                return kernel.fs.FileType.File;
            }
        });
    };
    return Internal.BufferedFileInst;
}
