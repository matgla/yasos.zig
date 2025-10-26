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

const c = @import("libc_imports").c;

const IFileSystem = @import("ifilesystem.zig").IFileSystem;
const IDirectoryIterator = @import("idirectory.zig").IDirectoryIterator;
const IFile = @import("ifile.zig").IFile;
const MountPoints = @import("mount_points.zig").MountPoints;
const MountPoint = @import("mount_points.zig").MountPoint;

const kernel = @import("../kernel.zig");

const interface = @import("interface");

const log = std.log.scoped(.vfs);

pub const VirtualFileSystem = interface.DeriveFromBase(IFileSystem, struct {
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

    pub fn create(self: *Self, path: []const u8, mode: i32) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return try node.point.filesystem.interface.create(node.left, mode);
        }
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return try node.point.filesystem.interface.mkdir(node.left, mode);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return node.point.filesystem.interface.unlink(node.left);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "vfs";
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return try node.point.filesystem.interface.get(node.left);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn delete(self: *Self) void {
        self.mount_points.deinit();
    }

    pub fn format(self: *Self) anyerror!void {
        // VirtualFileSystem does not support formatting
        _ = self;
        return error.NotSupported;
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            const trimmed_path = std.mem.trim(u8, node.left, "/ ");
            return try node.point.filesystem.interface.stat(trimmed_path, data);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    // Below are part of VirtualFileSystem interface, not IFileSystem
    pub fn init(allocator: std.mem.Allocator) VirtualFileSystem {
        return VirtualFileSystem.init(.{
            .mount_points = MountPoints.init(allocator),
        });
    }

    pub fn deinit(self: *Self) void {
        log.info("Virtual file system deinitialization", .{});
        self.mount_points.deinit();
    }

    pub fn mount_filesystem(self: *Self, path: []const u8, fs: IFileSystem) !void {
        try self.mount_points.mount_filesystem(path, fs);
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = old_path;
        _ = new_path;
        return error.NotSupported;
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return try node.point.filesystem.interface.access(node.left, mode, flags);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }
});

var vfs_instance: ?VirtualFileSystem = null;
var vfs_object: ?IFileSystem = null;

pub fn vfs_init(allocator: std.mem.Allocator) void {
    log.info("initialization...", .{});
    vfs_instance = VirtualFileSystem.InstanceType.init(allocator);
    vfs_object = vfs_instance.?.interface.create();
}

pub fn vfs_deinit() void {
    log.info("deinitialization...", .{});
    if (vfs_instance) |*instance| {
        instance.deinit();
        vfs_instance = null;
    }
    vfs_object = null;
}

pub fn get_ivfs() *IFileSystem {
    if (vfs_object) |vfs| {
        return vfs;
    }
    @panic("vfs not initialized");
}

pub fn get_vfs() *VirtualFileSystem.InstanceType {
    if (vfs_instance) |*instance| {
        return instance.data();
    }
    @panic("vfs not initialized");
}

test "VirtualFileSystem.ShouldRedirectFileCreation" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    try sut.mount_filesystem("/", fs);

    _ = fs_mock
        .expectCall("create")
        .withArgs(.{ "dir", 0 });

    try sut.create("/dir", 0);
}
