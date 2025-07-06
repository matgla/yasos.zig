//
// vfs.zig
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

const IFileSystem = @import("ifilesystem.zig").IFileSystem;
const IDirectoryIterator = @import("ifilesystem.zig").IDirectoryIterator;
const IFile = @import("ifile.zig").IFile;
const MountPoints = @import("mount_points.zig").MountPoints;
const MountPoint = @import("mount_points.zig").MountPoint;

const interface = @import("interface");

pub const VirtualFileSystem = struct {
    pub usingnamespace interface.DeriveFromBase(IFileSystem, VirtualFileSystem);
    const Self = @This();
    mount_points: MountPoints,

    pub fn mount(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn umount(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn create(self: *Self, path: []const u8, mode: i32) ?IFile {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return node.point.filesystem.create(node.left, mode);
        }
        return null;
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) i32 {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return node.point.filesystem.mkdir(node.left, mode);
        }
        return -1;
    }

    pub fn remove(self: *Self, path: []const u8) i32 {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return node.point.filesystem.remove(node.left);
        }
        return -1;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "vfs";
    }

    pub fn traverse(self: *Self, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return node.point.filesystem.traverse(node.left, callback, user_context);
        }
        return -1;
    }

    pub fn iterator(self: *Self, path: []const u8) ?IDirectoryIterator {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return node.point.filesystem.iterator(node.left);
        }
        return null;
    }

    pub fn get(self: *Self, path: []const u8) ?IFile {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return node.point.filesystem.get(node.left);
        }
        return null;
    }

    pub fn has_path(self: *const Self, path: []const u8) bool {
        const maybe_node = self.mount_points.find_longest_matching_point(*const MountPoint, path);
        if (maybe_node) |*node| {
            // Check if the filesystem has the path
            return node.point.filesystem.has_path(node.left);
        }
        return false;
    }

    pub fn delete(self: *Self) void {
        self.mount_points.deinit();
    }

    // Below are part of VirtualFileSystem interface, not IFileSystem
    pub fn init(allocator: std.mem.Allocator) VirtualFileSystem {
        return .{
            .mount_points = MountPoints.init(allocator),
        };
    }

    pub fn mount_filesystem(self: *Self, path: []const u8, fs: IFileSystem) !void {
        try self.mount_points.mount_filesystem(path, fs);
    }
};

var vfs_instance: VirtualFileSystem = undefined;
var vfs_object: IFileSystem = undefined;

pub fn vfs_init(allocator: std.mem.Allocator) void {
    vfs_instance = VirtualFileSystem.init(allocator);
    vfs_object = vfs_instance.interface();
}

pub fn ivfs() *IFileSystem {
    return &vfs_object;
}

pub fn vfs() *VirtualFileSystem {
    return &vfs_instance;
}
