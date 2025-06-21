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

const std = @import("std");

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

pub const FileName = struct {
    name: []const u8,
    allocator: ?std.mem.Allocator,

    pub fn init(name: []const u8, allocator: ?std.mem.Allocator) FileName {
        return .{
            .name = name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: FileName) void {
        if (self.allocator) |alloc| {
            alloc.free(self.name);
        }
    }
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
        // filename may be heap allocated or stack, call always .deinit() after use
        name: *const fn (ctx: *const anyopaque) FileName,
        ioctl: *const fn (ctx: *anyopaque, cmd: i32, arg: ?*anyopaque) i32,
        fcntl: *const fn (ctx: *anyopaque, cmd: i32, arg: ?*anyopaque) i32,
        stat: *const fn (ctx: *const anyopaque, data: *c.struct_stat) void,
        filetype: *const fn (ctx: *const anyopaque) FileType,
        dupe: *const fn (ctx: *anyopaque) ?IFile,
        destroy: *const fn (ctx: *anyopaque) void, // destroy object, but do not close
    };

    pub fn init(ptr: anytype) IFile {
        const gen_vtable = struct {
            const vtable = VTable{
                .read = gen_read,
                .write = gen_write,
                .seek = gen_seek,
                .close = gen_close,
                .sync = gen_sync,
                .tell = gen_tell,
                .size = gen_size,
                .name = gen_name,
                .ioctl = gen_ioctl,
                .fcntl = gen_fcntl,
                .stat = gen_stat,
                .filetype = gen_filetype,
                .dupe = gen_dupe,
                .destroy = gen_destroy,
            };

            pub fn gen_read(ctx: *anyopaque, buf: []u8) isize {
                const self: @TypeOf(ptr) = @ptrCast(@alignCast(ctx));
                return self.read(buf);
            }

            pub fn gen_write(ctx: *anyopaque, buf: []const u8) isize {
                const self: @TypeOf(ptr) = @ptrCast(@alignCast(ctx));
                return self.write(buf);
            }

            pub fn gen_seek(ctx: *anyopaque, offset: c.off_t, base: i32) c.off_t {
                const self: @TypeOf(ptr) = @ptrCast(@alignCast(ctx));
                return self.seek(offset, base);
            }

            pub fn gen_close(ctx: *anyopaque) i32 {
                const self: @TypeOf(ptr) = @ptrCast(@alignCast(ctx));
                return self.close();
            }

            pub fn gen_sync(ctx: *anyopaque) i32 {
                const self: *Self = @ptrCast(@alignCast(ctx));
                return self.sync();
            }

            pub fn gen_tell(ctx: *anyopaque) c.off_t {
                const self: *Self = @ptrCast(@alignCast(ctx));
                return self.tell();
            }

            pub fn gen_size(ctx: *anyopaque) isize {
                const self: *Self = @ptrCast(@alignCast(ctx));
                return self.size();
            }

            pub fn gen_name(ctx: *const anyopaque) FileName {
                const self: *const Self = @ptrCast(@alignCast(ctx));
                return self.name();
            }

            pub fn gen_ioctl(ctx: *anyopaque, cmd: i32, arg: ?*anyopaque) i32 {
                const self: *Self = @ptrCast(@alignCast(ctx));
                return self.ioctl(cmd, arg);
            }

            pub fn gen_fcntl(ctx: *anyopaque, cmd: i32, arg: ?*anyopaque) i32 {
                const self: *Self = @ptrCast(@alignCast(ctx));
                return self.fcntl(cmd, arg);
            }

            pub fn gen_stat(ctx: *const anyopaque, data: *c.struct_stat) void {
                const self: *const Self = @ptrCast(@alignCast(ctx));
                self.stat(data);
            }

            pub fn gen_filetype(ctx: *const anyopaque) FileType {
                const self: *const Self = @ptrCast(@alignCast(ctx));
                return self.filetype();
            }

            pub fn gen_dupe(ctx: *anyopaque) ?IFile {
                const self: *Self = @ptrCast(@alignCast(ctx));
                return self.dupe();
            }

            pub fn gen_destroy(ctx: *anyopaque) void {
                const self: *Self = @ptrCast(@alignCast(ctx));
                self.destroy();
            }
        };
        return .{
            .ptr = ptr,
            .vtable = &gen_vtable.vtable,
        };
    }

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

    pub fn name(self: IFile) FileName {
        return self.vtable.name(self.ptr);
    }

    pub fn ioctl(self: IFile, cmd: i32, arg: ?*anyopaque) i32 {
        return self.vtable.ioctl(self.ptr, cmd, arg);
    }

    pub fn fcntl(self: IFile, cmd: i32, arg: ?*anyopaque) i32 {
        return self.vtable.fcntl(self.ptr, cmd, arg);
    }

    pub fn stat(self: IFile, data: *c.struct_stat) void {
        return self.vtable.stat(self.ptr, data);
    }

    pub fn filetype(self: IFile) FileType {
        return self.vtable.filetype(self.ptr);
    }

    pub fn dupe(self: IFile) ?IFile {
        return self.vtable.dupe(self.ptr);
    }

    pub fn destroy(self: IFile) void {
        return self.vtable.destroy(self.ptr);
    }
};
