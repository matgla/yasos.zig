//
// filesystem.zig
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

const IFile = @import("ifile.zig").IFile;

const interface = @import("interface");

fn DirectoryIteratorInterface(comptime SelfType: type) type {
    return struct {
        pub const Self = SelfType;

        pub fn next(self: *Self) ?IFile {
            return interface.VirtualCall(self, "next", .{}, ?IFile);
        }

        pub fn delete(self: *Self) void {
            interface.DestructorCall(self);
            interface.VirtualCall(self, "delete", .{}, void);
        }
    };
}

fn FileSystemInterface(comptime SelfType: type) type {
    return struct {
        pub const Self = SelfType;

        pub fn mount(self: *Self) i32 {
            return interface.VirtualCall(self, "mount", .{}, i32);
        }

        pub fn umount(self: *Self) i32 {
            return interface.VirtualCall(self, "umount", .{}, i32);
        }

        pub fn create(self: *Self, path: []const u8, flags: i32, allocator: std.mem.Allocator) ?IFile {
            return interface.VirtualCall(self, "create", .{ path, flags, allocator }, ?IFile);
        }

        pub fn mkdir(self: *Self, path: []const u8, mode: i32) i32 {
            return interface.VirtualCall(self, "mkdir", .{ path, mode }, i32);
        }

        pub fn remove(self: *Self, path: []const u8) i32 {
            return interface.VirtualCall(self, "remove", .{path}, i32);
        }

        pub fn name(self: *const Self) []const u8 {
            return interface.VirtualCall(self, "name", .{}, []const u8);
        }

        pub fn traverse(self: *Self, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
            return interface.VirtualCall(self, "traverse", .{ path, callback, user_context }, i32);
        }

        pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?IFile {
            return interface.VirtualCall(self, "get", .{ path, allocator }, ?IFile);
        }

        pub fn has_path(self: *const Self, path: []const u8) bool {
            return interface.VirtualCall(self, "has_path", .{path}, bool);
        }

        pub fn delete(self: *Self) void {
            interface.VirtualCall(self, "delete", .{}, void);
            interface.DestructorCall(self);
        }

        pub fn iterator(self: *Self, path: []const u8) ?IDirectoryIterator {
            return interface.VirtualCall(self, "iterator", .{path}, ?IDirectoryIterator);
        }
    };
}

pub const ReadOnlyFileSystem = struct {
    pub const Self = @This();
    pub usingnamespace interface.DeriveFromBase(IFileSystem, Self);

    pub fn mount(self: *Self) i32 {
        _ = self;
        return 0; // Read-only filesystem does not need to do anything on mount
    }

    pub fn umount(self: *Self) i32 {
        _ = self;
        return 0; // Read-only filesystem does not need to do anything on unmount
    }

    pub fn create(self: *Self, path: []const u8, flags: i32, allocator: std.mem.Allocator) ?IFile {
        _ = self;
        _ = path;
        _ = flags;
        _ = allocator;
        return null; // Read-only filesystem does not allow file creation
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) i32 {
        _ = self;
        _ = path;
        _ = mode;
        return -1; // Read-only filesystem does not allow directory creation
    }

    pub fn remove(self: *Self, path: []const u8) i32 {
        _ = self;
        _ = path;
        return -1; // Read-only filesystem does not allow file removal
    }
};

pub const IFileSystem = interface.ConstructInterface(FileSystemInterface);
pub const IDirectoryIterator = interface.ConstructInterface(DirectoryIteratorInterface);
