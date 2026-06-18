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

const c = @import("libc_imports").c;

const IFile = @import("ifile.zig").IFile;

const interface = @import("interface");

const kernel = @import("../kernel.zig");

pub const IFileSystem = interface.ConstructInterface(struct {
    pub const Self = @This();

    pub fn mount(self: *Self) i32 {
        return interface.VirtualCall(self, "mount", .{}, i32);
    }

    pub fn umount(self: *Self) i32 {
        return interface.VirtualCall(self, "umount", .{}, i32);
    }

    pub fn create(self: *Self, path: []const u8, flags: i32) anyerror!void {
        return interface.VirtualCall(self, "create", .{ path, flags }, anyerror!void);
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        return interface.VirtualCall(self, "mkdir", .{ path, mode }, anyerror!void);
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        return interface.VirtualCall(self, "unlink", .{path}, anyerror!void);
    }

    pub fn name(self: *const Self) []const u8 {
        return interface.VirtualCall(self, "name", .{}, []const u8);
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        return interface.VirtualCall(self, "get", .{path}, anyerror!kernel.fs.Node);
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        return interface.VirtualCall(self, "link", .{ old_path, new_path }, anyerror!void);
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        return interface.VirtualCall(self, "access", .{ path, mode, flags }, anyerror!void);
    }

    pub fn delete(self: *Self) void {
        interface.DestructorCall(self);
    }

    pub fn format(self: *Self) anyerror!void {
        try interface.VirtualCall(self, "format", .{}, anyerror!void);
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_links: bool) anyerror!void {
        return interface.VirtualCall(self, "stat", .{ path, data, follow_links }, anyerror!void);
    }

    // Read a symbolic link's target into `buffer`, returning the number of bytes
    // written. Filesystems that do not support symlinks return InvalidArgument
    // (EINVAL: "not a symbolic link").
    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        return interface.VirtualCall(self, "readlink", .{ path, buffer }, anyerror!usize);
    }

    // Create a symbolic link at `linkpath` pointing to `target`.
    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        return interface.VirtualCall(self, "symlink", .{ target, linkpath }, anyerror!void);
    }
});

pub const ReadOnlyFileSystem = interface.DeriveFromBase(IFileSystem, struct {
    pub const Self = @This();

    pub fn mount(self: *Self) i32 {
        _ = self;
        return 0; // Read-only filesystem does not need to do anything on mount
    }

    pub fn umount(self: *Self) i32 {
        _ = self;
        return 0; // Read-only filesystem does not need to do anything on unmount
    }

    pub fn create(self: *Self, path: []const u8, flags: i32) anyerror!void {
        _ = self;
        _ = path;
        _ = flags;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        _ = self;
        _ = path;
        _ = mode;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem does not allow directory creation
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = old_path;
        _ = new_path;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem does not allow linking
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        _ = self;
        _ = path;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem does not allow unlinking
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem cannot be formatted
    }

    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        _ = self;
        _ = path;
        _ = buffer;
        return kernel.errno.ErrnoSet.InvalidArgument; // not a symbolic link
    }

    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        _ = self;
        _ = target;
        _ = linkpath;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem does not allow symlinking
    }
});
