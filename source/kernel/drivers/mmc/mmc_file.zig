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

const c = @import("../../../libc_imports.zig").c;

const IFile = @import("../../fs/ifile.zig").IFile;
const FileType = @import("../../fs/ifile.zig").FileType;

pub fn MmcFile(comptime MmcType: anytype) type {
    return struct {
        const Self = @This();
        const mmc = MmcType;

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

        _allocator: std.mem.Allocator,

        pub fn new(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Self {
            const object = try allocator.create(Self);
            object.* = Self.create(allocator);
            return object;
        }

        pub fn destroy(self: *Self) void {
            self._allocator.destroy(self);
        }

        pub fn create(allocator: std.mem.Allocator) Self {
            return .{
                ._allocator = allocator,
            };
        }

        pub fn ifile(self: *Self) IFile {
            return .{
                .ptr = self,
                .vtable = &VTable,
            };
        }

        fn read(ctx: *anyopaque, buf: []u8) isize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
            _ = buf;
            return 0;
        }

        fn write(ctx: *anyopaque, buf: []const u8) isize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
            _ = buf;
            return 0;
        }

        fn seek(ctx: *anyopaque, offset: c.off_t, whence: i32) c.off_t {
            _ = ctx;
            _ = offset;
            _ = whence;
            return 0;
        }

        fn close(ctx: *anyopaque) i32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
            return 0;
            // return self.mmc.close();
        }

        fn sync(ctx: *anyopaque) i32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
            return 0;
        }

        fn tell(ctx: *anyopaque) c.off_t {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
            return 0;
        }

        fn size(ctx: *anyopaque) isize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
            return 0;
        }

        fn name(ctx: *anyopaque) []const u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
            return "";
        }

        fn ioctl(ctx: *anyopaque, op: i32, arg: ?*anyopaque) i32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
            _ = op;
            _ = arg;
            return 0;
        }

        fn fcntl(ctx: *anyopaque, op: i32, maybe_arg: ?*anyopaque) i32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = self;
            _ = op;
            _ = maybe_arg;
            return 0;
        }

        fn stat(ctx: *const anyopaque, buf: *c.struct_stat) void {
            _ = ctx;
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

        fn filetype(_: *const anyopaque) FileType {
            return FileType.BlockDevice;
        }

        pub fn dupe(ctx: *anyopaque) ?IFile {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.ifile();
        }

        fn _destroy(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.destroy();
        }
    };
}
