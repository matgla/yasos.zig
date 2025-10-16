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

const c = @import("libc_imports").c;

const interface = @import("interface");

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
    Unknown = 128,
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
    _name: []const u8,
    _allocator: ?std.mem.Allocator,

    pub fn init(name: []const u8, allocator: ?std.mem.Allocator) FileName {
        return .{
            ._name = name,
            ._allocator = allocator,
        };
    }

    pub fn deinit(self: FileName) void {
        if (self._allocator) |alloc| {
            alloc.free(self._name);
        }
    }

    pub fn get_name(self: *const FileName) []const u8 {
        const zero_index = std.mem.indexOfScalar(u8, self._name, 0) orelse self._name.len;
        return self._name[0..zero_index];
    }
};

pub const IFile = interface.ConstructCountingInterface(struct {
    pub const Self = @This();

    pub fn read(self: *Self, buf: []u8) isize {
        return interface.CountingInterfaceVirtualCall(self, "read", .{buf}, isize);
    }

    pub fn write(self: *Self, buf: []const u8) isize {
        return interface.CountingInterfaceVirtualCall(self, "write", .{buf}, isize);
    }

    pub fn seek(self: *Self, offset: c.off_t, base: i32) c.off_t {
        return interface.CountingInterfaceVirtualCall(self, "seek", .{ offset, base }, c.off_t);
    }

    pub fn close(self: *Self) void {
        return interface.CountingInterfaceVirtualCall(self, "close", .{}, void);
    }

    pub fn sync(self: *Self) i32 {
        return interface.CountingInterfaceVirtualCall(self, "sync", .{}, i32);
    }

    pub fn tell(self: *Self) c.off_t {
        return interface.CountingInterfaceVirtualCall(self, "tell", .{}, c.off_t);
    }

    pub fn size(self: *Self) isize {
        return interface.CountingInterfaceVirtualCall(self, "size", .{}, isize);
    }

    pub fn name(self: *const Self) []const u8 {
        return interface.CountingInterfaceVirtualCall(self, "name", .{}, []const u8);
    }

    pub fn ioctl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
        return interface.CountingInterfaceVirtualCall(self, "ioctl", .{ cmd, arg }, i32);
    }

    pub fn fcntl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
        return interface.CountingInterfaceVirtualCall(self, "fcntl", .{ cmd, arg }, i32);
    }

    pub fn filetype(self: *const Self) FileType {
        return interface.CountingInterfaceVirtualCall(self, "filetype", .{}, FileType);
    }

    pub fn delete(self: *Self) void {
        interface.CountingInterfaceDestructorCall(self);
    }
});

pub const ReadOnlyFile = interface.DeriveFromBase(IFile, struct {
    pub const Self = @This();

    pub fn write(self: *Self, buf: []const u8) isize {
        _ = self;
        _ = buf;
        return -1;
    }

    pub fn sync(self: *Self) i32 {
        _ = self;
        return -1;
    }
});

pub const IDirectory = interface.DeriveFromBase(IFile, struct {
    pub const Self = @This();

    pub fn write(self: *Self, buf: []const u8) isize {
        _ = self;
        _ = buf;
        return -1;
    }

    pub fn sync(self: *Self) i32 {
        _ = self;
        return -1;
    }
});
