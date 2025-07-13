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

fn FileInterface(comptime SelfType: type) type {
    return struct {
        pub const Self = SelfType;

        pub fn read(self: *Self, buf: []u8) isize {
            return interface.VirtualCall(self, "read", .{buf}, isize);
        }

        pub fn write(self: *Self, buf: []const u8) isize {
            return interface.VirtualCall(self, "write", .{buf}, isize);
        }

        pub fn seek(self: *Self, offset: c.off_t, base: i32) c.off_t {
            return interface.VirtualCall(self, "seek", .{ offset, base }, c.off_t);
        }

        pub fn close(self: *Self) i32 {
            return interface.VirtualCall(self, "close", .{}, i32);
        }

        pub fn sync(self: *Self) i32 {
            return interface.VirtualCall(self, "sync", .{}, i32);
        }

        pub fn tell(self: *Self) c.off_t {
            return interface.VirtualCall(self, "tell", .{}, c.off_t);
        }

        pub fn size(self: *Self) isize {
            return interface.VirtualCall(self, "size", .{}, isize);
        }

        pub fn name(self: *Self, allocator: std.mem.Allocator) FileName {
            return interface.VirtualCall(self, "name", .{allocator}, FileName);
        }

        pub fn ioctl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
            return interface.VirtualCall(self, "ioctl", .{ cmd, arg }, i32);
        }

        pub fn fcntl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
            return interface.VirtualCall(self, "fcntl", .{ cmd, arg }, i32);
        }

        pub fn stat(self: *Self, data: *c.struct_stat) void {
            return interface.VirtualCall(self, "stat", .{data}, void);
        }

        pub fn filetype(self: *Self) FileType {
            return interface.VirtualCall(self, "filetype", .{}, FileType);
        }

        pub fn delete(self: *Self) void {
            if (self.__refcount) |r| {
                if (r.* == 1) {
                    interface.VirtualCall(self, "delete", .{}, void);
                }
            }
            interface.DestructorCall(self);
        }
    };
}

pub const IFile = interface.ConstructCountingInterface(FileInterface);
pub const ReadOnlyFile = struct {
    pub const Self = @This();
    pub usingnamespace interface.DeriveFromBase(IFile, Self);

    pub fn write(self: *Self, buf: []const u8) isize {
        _ = self;
        _ = buf;
        return -1;
    }

    pub fn sync(self: *Self) i32 {
        _ = self;
        return -1;
    }
};
