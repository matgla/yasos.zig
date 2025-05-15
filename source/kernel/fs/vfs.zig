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
const IFile = @import("ifile.zig").IFile;
const MountPoints = @import("mount_points.zig").MountPoints;

pub const VirtualFileSystem = struct {
    const VTable = IFileSystem.VTable{
        .mount = mount,
        .umount = umount,
        .create = create,
        .mkdir = mkdir,
        .remove = remove,
        .name = name,
        .traverse = traverse,
        .get = get,
        .has_path = has_path,
    };
    mount_points: MountPoints,

    pub fn init(allocator: std.mem.Allocator) VirtualFileSystem {
        return .{
            .mount_points = MountPoints.init(allocator),
        };
    }

    pub fn mount_filesystem(self: *VirtualFileSystem, path: []const u8, fs: IFileSystem) !void {
        try self.mount_points.mount_filesystem(path, fs);
    }

    pub fn ifilesystem(self: *VirtualFileSystem) IFileSystem {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    fn mount(_: *anyopaque) i32 {
        return 0;
    }

    fn umount(_: *anyopaque) i32 {
        return 0;
    }

    fn create(ctx: *anyopaque, path: []const u8, mode: i32) ?IFile {
        const self: *VirtualFileSystem = @ptrCast(@alignCast(ctx));
        const maybe_node = self.mount_points.find_longest_matching_point(path);
        return maybe_node.point.filesystem.create(maybe_node.left, mode);
    }

    fn mkdir(ctx: *anyopaque, path: []const u8, mode: i32) i32 {
        const self: *VirtualFileSystem = @ptrCast(@alignCast(ctx));
        const maybe_node = self.mount_points.find_longest_matching_point(path);
        return maybe_node.point.filesystem.mkdir(maybe_node.left, mode);
    }

    fn remove(ctx: *anyopaque, path: []const u8) i32 {
        const self: *VirtualFileSystem = @ptrCast(@alignCast(ctx));
        const maybe_node = self.mount_points.find_longest_matching_point(path);
        return maybe_node.point.filesystem.remove(maybe_node.left);
    }

    fn name(_: *const anyopaque) []const u8 {
        return "vfs";
    }

    fn traverse(ctx: *anyopaque, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
        const self: *VirtualFileSystem = @ptrCast(@alignCast(ctx));
        const maybe_node = self.mount_points.find_longest_matching_point(path);
        return maybe_node.point.filesystem.traverse(maybe_node.left, callback, user_context);
    }

    fn get(ctx: *anyopaque, path: []const u8) ?IFile {
        const self: *VirtualFileSystem = @ptrCast(@alignCast(ctx));
        const maybe_node = self.mount_points.find_longest_matching_point(path);
        return maybe_node.point.filesystem.get(maybe_node.left);
    }

    fn has_path(ctx: *anyopaque, path: []const u8) bool {
        const self: *VirtualFileSystem = @ptrCast(@alignCast(ctx));
        const maybe_node = self.mount_points.find_longest_matching_point(path);
        return maybe_node.point.filesystem.has_path(maybe_node.left);
    }
};

var vfs_instance: VirtualFileSystem = undefined;
var vfs_object: IFileSystem = undefined;

pub fn vfs_init(allocator: std.mem.Allocator) void {
    vfs_instance = VirtualFileSystem.init(allocator);
    vfs_object = vfs_instance.ifilesystem();
}

pub fn ivfs() *IFileSystem {
    return &vfs_object;
}

pub fn vfs() *VirtualFileSystem {
    return &vfs_instance;
}
