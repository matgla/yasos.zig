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

const interface = @import("interface");

const c = @import("libc_imports").c;

const kernel = @import("../../kernel.zig");

pub const FileStub = interface.DeriveFromBase(kernel.fs.IFile, struct {
    const Self = @This();
    _name: []const u8,
    pub fn init(filename: []const u8) FileStub {
        return FileStub.init(.{
            ._name = filename,
        });
    }

    pub fn read(self: *Self, buf: []u8) isize {
        _ = self;
        _ = buf;
        return 0;
    }

    pub fn write(self: *Self, buf: []const u8) isize {
        _ = self;
        _ = buf;
        return 0;
    }

    pub fn seek(self: *Self, offset: c.off_t, base: i32) c.off_t {
        _ = self;
        _ = offset;
        _ = base;
        return 0;
    }

    pub fn close(self: *Self) i32 {
        _ = self;
        return 0;
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
        _ = self;
        return 0;
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
        return kernel.fs.FileType.File;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
