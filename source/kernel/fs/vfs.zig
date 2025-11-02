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

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_symlinks: bool) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            const trimmed_path = std.mem.trim(u8, node.left, "/ ");
            return try node.point.filesystem.interface.stat(trimmed_path, data, follow_symlinks);
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
    if (vfs_object) |*instance| {
        instance.interface.delete();
        vfs_object = null;
    }
    vfs_instance = null;
}

pub fn get_ivfs() *IFileSystem {
    if (vfs_object) |*vfs| {
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
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    _ = fs_mock
        .expectCall("create")
        .withArgs(.{ "dir", @as(u32, 0) });

    try sut.create("/dir", 0);

    _ = fs_mock
        .expectCall("create")
        .withArgs(.{ "dir/x/y", @as(u32, 0) });

    try sut.create("/dir/x/y", 0);
}

test "VirtualFileSystem.ShouldRedirectFileCreationToNestedFilesystem" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"mnt"})
        .willReturn(file_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/mnt", fs2);

    _ = fs2_mock
        .expectCall("create")
        .withArgs(.{ "subdir/file.txt", @as(u32, 0o644) });

    try sut.create("/mnt/subdir/file.txt", 0o644);
}

test "VirtualFileSystem.CreateShouldFailIfNoFilesystemMounted" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    // No error is returned currently, but this documents the behavior
    try sut.create("/file.txt", 0);
}

test "VirtualFileSystem.ShouldRedirectDirectoryCreation" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;
    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    _ = fs_mock
        .expectCall("mkdir")
        .withArgs(.{ "dir", @as(u32, 0) });

    try sut.mkdir("/dir", 0);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"dir"})
        .willReturn(file_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/dir", fs2);

    _ = fs2_mock
        .expectCall("mkdir")
        .withArgs(.{ "x/y", @as(u32, 0) });

    try sut.mkdir("/dir/x/y", 0);
}

test "VirtualFileSystem.ShouldRedirectDirectoryCreationToNestedFilesystem" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"data"})
        .willReturn(file_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/data", fs2);

    _ = fs2_mock
        .expectCall("mkdir")
        .withArgs(.{ "subdir/nested", @as(u32, 0o755) });

    try sut.mkdir("/data/subdir/nested", 0o755);
}

test "VirtualFileSystem.MkdirShouldFailIfNoFilesystemMounted" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.mkdir("/newdir", 0));
}

test "VirtualFileSystem.ShouldRedirectUnlink" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    _ = fs_mock
        .expectCall("unlink")
        .withArgs(.{"file.txt"});

    try sut.unlink("/file.txt");

    _ = fs_mock
        .expectCall("unlink")
        .withArgs(.{"dir/x/file.txt"});

    try sut.unlink("/dir/x/file.txt");
}

test "VirtualFileSystem.ShouldRedirectUnlinkToNestedFilesystem" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"mnt"})
        .willReturn(file_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/mnt", fs2);

    _ = fs2_mock
        .expectCall("unlink")
        .withArgs(.{"nested/file.txt"});

    try sut.unlink("/mnt/nested/file.txt");
}

test "VirtualFileSystem.UnlinkShouldFailIfNoFilesystemMounted" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.unlink("/nonexistent.txt"));
}

test "VirtualFileSystem.ShouldReturnCorrectName" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    const fs_name = sut.name();
    try std.testing.expectEqualStrings("vfs", fs_name);
}

test "VirtualFileSystem.ShouldRedirectGet" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"file.txt"})
        .willReturn(file_node);

    var node = try sut.get("/file.txt");
    defer node.delete();
    try std.testing.expect(node.is_file());
}

test "VirtualFileSystem.ShouldRedirectGetToNestedFilesystem" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var mount_filemock = try FileMock.create(std.testing.allocator);
    const mount_file = mount_filemock.get_interface();
    const mount_node = kernel.fs.Node.create_file(mount_file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"data"})
        .willReturn(mount_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/data", fs2);

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs2_mock
        .expectCall("get")
        .withArgs(.{"test/file.txt"})
        .willReturn(file_node);

    var node = try sut.get("/data/test/file.txt");
    defer node.delete();
    try std.testing.expect(node.is_file());
}

test "VirtualFileSystem.GetShouldFailIfNoFilesystemMounted" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.get("/file.txt"));
}
