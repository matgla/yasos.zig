//
// mount_points.zig
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

const config = @import("config");

const MountPoint = struct {
    pub const List = std.DoublyLinkedList;
    path_buffer: [config.fs.max_mount_point_size]u8,
    path: []u8,
    filesystem: IFileSystem,
    children: List,
    list_node: List.Node,

    pub fn appendChild(self: *MountPoint, allocator: std.mem.Allocator, path: []const u8, filesystem: IFileSystem) !void {
        const point = try allocator.create(MountPoint);
        point.* = .{
            .path_buffer = undefined,
            .path = undefined,
            .filesystem = filesystem,
            .children = .{},
            .list_node = .{},
        };
        @memcpy(point.path_buffer[0..path.len], path);
        point.path = point.path_buffer[0..path.len];
        self.children.append(&point.list_node);
    }

    pub fn removeChild(self: *MountPoint, allocator: std.mem.Allocator, child_path: []const u8) void {
        var next = self.children.first;
        while (next) |node| {
            const child: *MountPoint = @fieldParentPtr("list_node", node);
            next = node.next;
            if (std.mem.eql(u8, child_path, child.path)) {
                self.children.remove(&child.list_node);
                allocator.destroy(child);
                return;
            }
        }
    }

    pub fn deinit(self: *MountPoint, allocator: std.mem.Allocator) void {
        var it = self.children.pop();
        while (it) |node| {
            const child: *MountPoint = @fieldParentPtr("list_node", node);
            child.deinit(allocator);
            it = self.children.pop();
            allocator.destroy(child);
        }
    }
};

pub const MountPointError = error{
    PathTooLong,
    MountPointNotAbsolutePath,
    RootNotMounted,
    MountPointInUse,
    PathNotExists,
    NotMounted,
};

pub const MountPoints = struct {
    allocator: std.mem.Allocator,
    root: ?MountPoint = null,

    pub fn init(allocator: std.mem.Allocator) MountPoints {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MountPoints) void {
        if (self.root) |*root| {
            root.deinit(self.allocator);
        }
    }

    pub fn find_longest_matching_point(self: *MountPoints, path: []const u8) ?struct {
        left: []const u8,
        point: *MountPoint,
        parent: ?*MountPoint,
    } {
        if (self.root == null) {
            return null;
        }
        var maybe_node: ?*MountPoint = &self.root.?;
        var last_matched_point: *MountPoint = &self.root.?;
        var parent: *MountPoint = &self.root.?;
        // skip root searching, already checked
        var left: []const u8 = std.mem.trim(u8, path, "/");
        while (maybe_node) |mountpoint| {
            // already finished
            if (left.len == 0) {
                break;
            }

            // traverse children
            var next = mountpoint.children.first;
            var bestchild: ?*MountPoint = null;

            while (next) |node| {
                const child: *MountPoint = @fieldParentPtr("list_node", node);
                next = node.next;
                if (std.mem.startsWith(u8, left, child.path)) {
                    if (bestchild == null) {
                        bestchild = child;
                        continue;
                    }
                    if (child.path.len > bestchild.?.path.len) {
                        bestchild = child;
                    }
                }
            }

            if (bestchild) |child| {
                parent = mountpoint;
                left = std.mem.trimLeft(u8, left[child.path.len..], "/");
                last_matched_point = child;
            }
            maybe_node = bestchild;
        }
        return .{
            .left = left,
            .point = last_matched_point,
            .parent = parent,
        };
    }

    fn mount_root(self: *MountPoints, path: []const u8, filesystem: IFileSystem) !void {
        if (!std.mem.eql(u8, path, "/")) {
            return MountPointError.RootNotMounted;
        }
        self.root = .{
            .path_buffer = undefined,
            .path = undefined,
            .filesystem = filesystem,
            .children = .{},
            .list_node = .{},
        };
        @memcpy(self.root.?.path_buffer[0..path.len], path);
        self.root.?.path = self.root.?.path_buffer[0..path.len];
    }

    pub fn mount_filesystem(self: *MountPoints, path: []const u8, filesystem: IFileSystem) !void {
        if (path.len + 1 > config.fs.max_mount_point_size) {
            return error.PathTooLong;
        }

        if (self.root == null) {
            try self.mount_root(path, filesystem);
            return;
        }

        if (path.len == 0 or path[0] != '/') {
            return MountPointError.MountPointNotAbsolutePath;
        }

        const maybe_longest_matching_point = self.find_longest_matching_point(path);
        if (maybe_longest_matching_point == null) {
            return MountPointError.RootNotMounted;
        }
        const longest_matching_point = maybe_longest_matching_point.?;
        if (longest_matching_point.left.len == 0) {
            return MountPointError.MountPointInUse;
        }

        // verify if path exists in FS and mount if so
        if (longest_matching_point.point.filesystem.has_path(longest_matching_point.left)) {
            try longest_matching_point.point.appendChild(self.allocator, longest_matching_point.left, filesystem);
        } else {
            return MountPointError.PathNotExists;
        }
    }

    pub fn umount(self: *MountPoints, path: []const u8) !void {
        const maybe_longest_matching_point = self.find_longest_matching_point(path);
        if (maybe_longest_matching_point == null) {
            return MountPointError.NotMounted;
        }
        const longest_matching_point = maybe_longest_matching_point.?;
        if (longest_matching_point.left.len != 0) {
            return MountPointError.NotMounted;
        }

        longest_matching_point.point.deinit(self.allocator);
        if (longest_matching_point.parent) |parent| {
            parent.removeChild(self.allocator, longest_matching_point.point.path);
        }

        if (std.mem.eql(u8, path, "/")) {
            self.root = null;
        }
    }
};

// Unit Tests
const FileSystemStub = struct {
    has_file: bool = true,

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

    pub fn ifilesystem(self: *FileSystemStub) IFileSystem {
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
    fn create(_: *anyopaque, _: []const u8, _: i32) ?IFile {
        return null;
    }
    fn mkdir(_: *anyopaque, _: []const u8, _: i32) i32 {
        return 0;
    }

    pub fn remove(_: *anyopaque, _: []const u8) i32 {
        return 0;
    }

    pub fn name(_: *const anyopaque) []const u8 {
        return "";
    }

    pub fn traverse(_: *const anyopaque, _: []const u8, _: *const fn (file: *IFile, _: *anyopaque) bool, _: *anyopaque) i32 {
        return 0;
    }

    pub fn get(_: *const anyopaque, _: []const u8) ?IFile {
        return null;
    }

    fn has_path(ctx: *anyopaque, _: []const u8) bool {
        const self: *const FileSystemStub = @ptrCast(@alignCast(ctx));
        return self.has_file;
    }
};

test "error when root not mounted" {
    var sut = MountPoints.init(std.testing.allocator);
    var fsstub = FileSystemStub{};
    try std.testing.expectError(MountPointError.RootNotMounted, sut.mount_filesystem("/a", fsstub.ifilesystem()));
}

test "mount root" {
    var sut = MountPoints.init(std.testing.allocator);
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expect(sut.root != null);
    try std.testing.expectEqualStrings("/", sut.root.?.path);
}

test "reject too long path" {
    var sut = MountPoints.init(std.testing.allocator);
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expectError(MountPointError.PathTooLong, sut.mount_filesystem("/" ** (config.fs.max_mount_point_size + 1), fsstub.ifilesystem()));
}

test "reject root if already mounted" {
    var sut = MountPoints.init(std.testing.allocator);
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/", fsstub.ifilesystem()));
}

test "mount childs" {
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();
    var fsstub = FileSystemStub{};
    var maybe_child = sut.find_longest_matching_point("/a/b/x/d");
    try std.testing.expect(maybe_child == null);

    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try sut.mount_filesystem("/a/b", fsstub.ifilesystem());

    try std.testing.expect(sut.root != null);
    try std.testing.expectEqual(1, sut.root.?.children.len());
    maybe_child = sut.find_longest_matching_point("/a/b/x/d");

    try std.testing.expect(maybe_child != null);
    var child = maybe_child.?;
    try std.testing.expectEqualStrings("x/d", child.left);
    try std.testing.expectEqualStrings("a/b", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);

    maybe_child = sut.find_longest_matching_point("/a/c");
    try std.testing.expect(maybe_child != null);

    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c", child.left);
    try std.testing.expectEqualStrings("/", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);

    maybe_child = sut.find_longest_matching_point("a/c/d");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/d", child.left);
    try std.testing.expectEqualStrings("/", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);

    try sut.mount_filesystem("/a/c", fsstub.ifilesystem());
    maybe_child = sut.find_longest_matching_point("a/c/d");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("d", child.left);
    try std.testing.expectEqualStrings("a/c", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);

    try sut.mount_filesystem("/a/c/a/c/", fsstub.ifilesystem());
    maybe_child = sut.find_longest_matching_point("a/c/a");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a", child.left);
    try std.testing.expectEqualStrings("a/c", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);
    maybe_child = sut.find_longest_matching_point("a/c/a/c/d/u/p");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("d/u/p", child.left);
    try std.testing.expectEqualStrings("a/c", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("a/c", child.parent.?.path);

    try sut.mount_filesystem("/a/c/a/c/e", fsstub.ifilesystem());
    maybe_child = sut.find_longest_matching_point("/a/c/a/c/e/deep/path/is/here");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("deep/path/is/here", child.left);
    try std.testing.expectEqualStrings("e", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("a/c", child.parent.?.path);

    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/b", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c/a/c", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c/a/c/e", fsstub.ifilesystem()));
}

test "report error when trying to mount relative path" {
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expectError(MountPointError.MountPointNotAbsolutePath, sut.mount_filesystem("otherfs/smth", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointNotAbsolutePath, sut.mount_filesystem("", fsstub.ifilesystem()));
}

test "handle not existing path" {
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();
    var fsstub = FileSystemStub{ .has_file = false };
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expectError(MountPointError.PathNotExists, sut.mount_filesystem("/a/c", fsstub.ifilesystem()));
    fsstub.has_file = true;
    try sut.mount_filesystem("/a/c", fsstub.ifilesystem());
    fsstub.has_file = false;
    try std.testing.expectError(MountPointError.PathNotExists, sut.mount_filesystem("/a/c/d", fsstub.ifilesystem()));
}

test "remove childs" {
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try sut.mount_filesystem("/a/b", fsstub.ifilesystem());
    try sut.mount_filesystem("/a/c", fsstub.ifilesystem());
    try sut.mount_filesystem("/a/c/a/c/", fsstub.ifilesystem());
    try sut.mount_filesystem("/a/c/e", fsstub.ifilesystem());
    try sut.mount_filesystem("/a/c/e/c/f", fsstub.ifilesystem());

    var maybe_child = sut.find_longest_matching_point("/a/c/e/c/f/deep/path");
    try std.testing.expect(maybe_child != null);
    var child = maybe_child.?;
    try std.testing.expectEqualStrings("deep/path", child.left);
    maybe_child = sut.find_longest_matching_point("/a/b/c");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("c", child.left);

    maybe_child = sut.find_longest_matching_point("/a/c/d");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("d", child.left);

    maybe_child = sut.find_longest_matching_point("/a/c/a/c/x");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("x", child.left);

    maybe_child = sut.find_longest_matching_point("/a/c/e/f");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("f", child.left);

    maybe_child = sut.find_longest_matching_point("/a/b");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("", child.left);

    _ = try sut.umount("/a/c");

    maybe_child = sut.find_longest_matching_point("/a/c/e/c/f/deep/path");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/e/c/f/deep/path", child.left);
    maybe_child = sut.find_longest_matching_point("/a/b/c");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("c", child.left);

    maybe_child = sut.find_longest_matching_point("/a/c/d");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/d", child.left);

    maybe_child = sut.find_longest_matching_point("/a/c/a/c/x");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/a/c/x", child.left);

    maybe_child = sut.find_longest_matching_point("/a/c/e/f");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/e/f", child.left);

    maybe_child = sut.find_longest_matching_point("/a/b");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("", child.left);
}
