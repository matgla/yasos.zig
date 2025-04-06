//
// file.zig
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

const c = @import("../../libc_imports.zig").c;

pub const FileType = enum(u8) {
    HardLink = 0,
    Directory = 1,
    File = 2,
    SymbolicLink = 3,
    BlockDevice = 4,
    CharDevice = 5,
    Socket = 6,
    Fifo = 7,
};

pub const IoctlCommonCommands = enum(u32) {
    GetMemoryMappingStatus,
};

pub const FileMemoryMapAttributes = extern struct {
    is_memory_mapped: bool,
    mapped_address_r: ?*const anyopaque,
    mapped_address_w: ?*anyopaque,
};

pub const IFile = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, buf: []u8) isize,
        write: *const fn (ctx: *anyopaque, buf: []const u8) isize,
        seek: *const fn (ctx: *anyopaque, offset: c.off_t, base: i32) c.off_t,
        close: *const fn (ctx: *anyopaque) i32,
        sync: *const fn (ctx: *anyopaque) i32,
        tell: *const fn (ctx: *anyopaque) c.off_t,
        size: *const fn (ctx: *anyopaque) isize,
        name: *const fn (ctx: *anyopaque) []const u8,
        ioctl: *const fn (ctx: *anyopaque, cmd: i32, arg: ?*anyopaque) i32,
        stat: *const fn (ctx: *const anyopaque, data: *c.struct_stat) void,
        filetype: *const fn (ctx: *const anyopaque) FileType,
    };

    pub fn read(self: IFile, buf: []u8) isize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn write(self: IFile, buf: []const u8) isize {
        return self.vtable.write(self.ptr, buf);
    }

    pub fn seek(self: IFile, offset: c.off_t, base: i32) c.off_t {
        return self.vtable.seek(self.ptr, offset, base);
    }

    pub fn close(self: IFile) i32 {
        return self.vtable.close(self.ptr);
    }

    pub fn sync(self: IFile) i32 {
        return self.vtable.sync(self.ptr);
    }

    pub fn tell(self: IFile) c.off_t {
        return self.vtable.tell(self.ptr);
    }

    pub fn size(self: IFile) isize {
        return self.vtable.size(self.ptr);
    }

    pub fn name(self: IFile) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn ioctl(self: IFile, cmd: i32, arg: ?*anyopaque) i32 {
        return self.vtable.ioctl(self.ptr, cmd, arg);
    }

    pub fn stat(self: IFile, data: *c.struct_stat) void {
        return self.vtable.stat(self.ptr, data);
    }

    pub fn filetype(self: IFile) FileType {
        return self.vtable.filetype(self.ptr);
    }
};
