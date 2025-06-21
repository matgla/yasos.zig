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
const c = @import("../../../libc_imports.zig").c;

const IFile = @import("../../fs/ifile.zig").IFile;
const FileName = @import("../../fs/ifile.zig").FileName;
const FileType = @import("../../fs/ifile.zig").FileType;

pub fn FlashFile(comptime FlashType: anytype) type {
    return struct {
        const Self = @This();

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
            .fcntl = fcntl,
            .stat = stat,
            .filetype = filetype,
            .dupe = dupe,
            .destroy = _destroy,
        };

        _flash: *FlashType,
        _allocator: std.mem.Allocator,
        _current_address: u32,

        pub fn new(allocator: std.mem.Allocator, flash: *FlashType) std.mem.Allocator.Error!*Self {
            const object = try allocator.create(Self);
            object.* = Self.create(allocator, flash);
            object.* = .{
                ._flash = flash,
                ._allocator = allocator,
                ._current_address = 0,
            };
            return object;
        }

        pub fn destroy(self: *Self) void {
            self._allocator.destroy(self);
        }

        pub fn create(allocator: std.mem.Allocator, flash: *FlashType) Self {
            return .{
                ._flash = flash,
                ._allocator = allocator,
                ._current_address = 0,
            };
        }

        pub fn ifile(self: *Self) IFile {
            return .{
                .ptr = self,
                .vtable = &VTable,
            };
        }

        pub fn read(ctx: *anyopaque, buffer: []u8) isize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self._flash.read(self._current_address, buffer);
            return @intCast(buffer.len);
        }

        pub fn write(ctx: *anyopaque, data: []const u8) isize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self._flash.write(self._current_address, data);
            return @intCast(data.len);
        }

        pub fn seek(ctx: *anyopaque, offset: c.off_t, whence: i32) c.off_t {
            const self: *Self = @ptrCast(@alignCast(ctx));
            switch (whence) {
                c.SEEK_SET => {
                    if (offset < 0) {
                        return -1;
                    }
                    self._current_address = @intCast(offset);
                },
                else => return -1,
            }
            return 0;
        }

        pub fn close(_: *anyopaque) i32 {
            return 0;
        }

        pub fn sync(_: *anyopaque) i32 {
            return 0;
        }

        pub fn tell(_: *const anyopaque) c.off_t {
            return 0;
        }

        pub fn size(_: *const anyopaque) isize {
            return 0;
        }

        pub fn name(_: *const anyopaque) FileName {
            return FileName.init("flash", null);
        }

        pub fn ioctl(ctx: *anyopaque, op: i32, arg: ?*anyopaque) i32 {
            _ = ctx;
            _ = op;
            _ = arg;
            return -1;
        }

        pub fn fcntl(ctx: *anyopaque, op: i32, maybe_arg: ?*anyopaque) i32 {
            _ = ctx;
            _ = op;
            _ = maybe_arg;
            return -1;
        }

        pub fn stat(ctx: *const anyopaque, buf: *c.struct_stat) void {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            buf.st_dev = 0;
            buf.st_ino = 0;
            buf.st_mode = 0;
            buf.st_nlink = 0;
            buf.st_uid = 0;
            buf.st_gid = 0;
            buf.st_rdev = 0;
            buf.st_size = 0;
            buf.st_blksize = FlashType.BlockSize;
            buf.st_blocks = self._flash.get_number_of_blocks();
        }

        pub fn filetype(_: *const anyopaque) FileType {
            return FileType.BlockDevice;
        }

        pub fn dupe(ctx: *anyopaque) ?IFile {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.ifile();
        }

        pub fn _destroy(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.destroy();
        }
    };
}
