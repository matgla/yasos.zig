//
// uart_file.zig
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
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
});

const IFile = @import("../../fs/ifile.zig").IFile;
const FileType = @import("../../fs/ifile.zig").FileType;

pub fn UartFile(comptime UartType: anytype) type {
    return struct {
        const Self = @This();
        const uart = UartType;

        /// VTable for IFile interface
        const VTable = IFile.VTable{
            .read = read,
            .write = write,
            .seek = seek,
            .close = close,
            .sync = sync,
            .tell = tell,
            .size = size,
            .name = name,
            .ioctl = ioctl,
            .stat = stat,
            .filetype = filetype,
        };

        pub fn create() Self {
            return .{};
        }

        pub fn ifile(self: *Self) IFile {
            return .{
                .ptr = self,
                .vtable = &VTable,
            };
        }

        pub fn read(_: *anyopaque, buffer: []u8) isize {
            return @intCast(uart.read(buffer));
        }

        pub fn write(_: *anyopaque, data: []const u8) isize {
            const result = uart.write_some(data) catch return 0;
            return @intCast(result);
        }

        pub fn seek(_: *anyopaque, _: c.off_t, _: i32) c.off_t {
            return 0;
        }

        pub fn close(_: *anyopaque) i32 {
            return 0;
        }

        pub fn sync(_: *anyopaque) i32 {
            // always in sync
            return 0;
        }

        pub fn tell(_: *const anyopaque) c.off_t {
            return 0;
        }

        pub fn size(_: *const anyopaque) isize {
            return 0;
        }

        pub fn name(_: *const anyopaque) []const u8 {
            return "";
        }

        pub fn ioctl(_: *anyopaque, _: u32, _: *const anyopaque) i32 {
            return 0;
        }

        pub fn stat(_: *const anyopaque, buf: *c.struct_stat) void {
            buf.st_dev = 0;
            buf.st_ino = 0;
            buf.st_mode = 0;
            buf.st_nlink = 0;
            buf.st_uid = 0;
            buf.st_gid = 0;
            buf.st_rdev = 0;
            buf.st_size = 0;
            buf.st_blksize = 1;
            buf.st_blocks = 1;
        }

        pub fn filetype(_: *const anyopaque) FileType {
            return FileType.CharDevice;
        }
    };
}
