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

const config = @import("config");

pub const MountPoint = struct {
    pub const List = std.DoublyLinkedList(MountPoint);

    path_buffer: [config.fs.max_mount_point_size]u8,
    path: []u8,
    filesystem: IFileSystem,
    children: List,
};

pub const MountPointError = error{
    PathTooLong,
    MountPointNotAbsolutePath,
    RootNotMounted,
    MountPointInUse,
    PathNotExists,
};

pub const MountPoints = struct {
    allocator: std.mem.Allocator,
    root: ?MountPoint = null,

    pub fn init(allocator: std.mem.Allocator) MountPoints {
        return .{
            .allocator = allocator,
        };
    }

    fn find_longest_matching_point(self: *MountPoints, path: []const u8) struct { left: []const u8, point: *MountPoint } {
        if (self.root == null) {
            return .{
                .left = &.{},
                .point = undefined,
            };
        }
        var maybe_node: ?*MountPoint = &self.root.?;
        var last_matched_point: *MountPoint = &self.root.?;
        // skip root searching, already checked
        var left: []const u8 = std.mem.trim(u8, path, "/");
        while (maybe_node) |node| {
            // already finished
            if (left.len == 0) {
                break;
            }

            // traverse children
            var childit = node.children.first;
            var bestchild: ?*MountPoint = null;

            while (childit) |child| : (childit = child.next) {
                if (std.mem.startsWith(u8, left, child.data.path)) {
                    if (bestchild == null) {
                        bestchild = &child.data;
                        continue;
                    }
                    if (child.data.path.len > bestchild.?.path.len) {
                        bestchild = &child.data;
                    }
                }
            }

            if (bestchild) |child| {
                left = std.mem.trimLeft(u8, left[child.path.len..], "/");
                last_matched_point = child;
            }
            maybe_node = bestchild;
        }
        return .{
            .left = left,
            .point = last_matched_point,
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

        const longest_matching_point = self.find_longest_matching_point(path);
        if (longest_matching_point.left.len == 0) {
            return MountPointError.MountPointInUse;
        }

        // verify if path exists in FS and mount if so
        if (longest_matching_point.point.filesystem.has_path(longest_matching_point.left)) {
            const node = try self.allocator.create(MountPoint.List.Node);
            node.data = .{
                .path_buffer = undefined,
                .path = undefined,
                .filesystem = filesystem,
                .children = .{},
            };
            @memcpy(node.data.path_buffer[0..longest_matching_point.left.len], longest_matching_point.left);
            node.data.path = node.data.path_buffer[0..longest_matching_point.left.len];
            longest_matching_point.point.children.append(node);
        } else {
            return MountPointError.PathNotExists;
        }
    }
};

const FileSystemStub = struct {
    has_file: bool = true,

    const VTable = IFileSystem.VTable{
        .mount = mount,
        .has_path = has_path,
    };

    pub fn ifilesystem(self: *FileSystemStub) IFileSystem {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    fn mount(_: *anyopaque) void {}
    fn has_path(ctx: *anyopaque, _: []const u8) bool {
        const self: *const FileSystemStub = @ptrCast(@alignCast(ctx));
        return self.has_file;
    }
};

test "error when root not mounted" {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = allocator.allocator();
    var sut = MountPoints.init(gpa);
    var fsstub = FileSystemStub{};
    try std.testing.expectError(MountPointError.RootNotMounted, sut.mount_filesystem("/a", fsstub.ifilesystem()));
}

test "mount root" {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = allocator.allocator();
    var sut = MountPoints.init(gpa);
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expect(sut.root != null);
    try std.testing.expectEqualStrings("/", sut.root.?.path);
}

test "reject too long path" {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = allocator.allocator();
    var sut = MountPoints.init(gpa);
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expectError(MountPointError.PathTooLong, sut.mount_filesystem("/" ** (config.fs.max_mount_point_size + 1), fsstub.ifilesystem()));
}

test "reject root if already mounted" {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = allocator.allocator();
    var sut = MountPoints.init(gpa);
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/", fsstub.ifilesystem()));
}

test "mount childs" {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = allocator.allocator();
    var sut = MountPoints.init(gpa);
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try sut.mount_filesystem("/a/b", fsstub.ifilesystem());

    try std.testing.expect(sut.root != null);
    try std.testing.expectEqual(1, sut.root.?.children.len);

    try std.testing.expectEqual(0, sut.root.?.children.first.?.data.children.len);
    try std.testing.expectEqualStrings("a/b", sut.root.?.children.first.?.data.path);

    try sut.mount_filesystem("/a/c", fsstub.ifilesystem());

    try std.testing.expect(sut.root != null);
    try std.testing.expectEqual(2, sut.root.?.children.len);

    try std.testing.expectEqual(0, sut.root.?.children.first.?.data.children.len);
    try std.testing.expectEqual(0, sut.root.?.children.last.?.data.children.len);

    try std.testing.expectEqualStrings("a/b", sut.root.?.children.first.?.data.path);
    try std.testing.expectEqualStrings("a/c", sut.root.?.children.last.?.data.path);

    try sut.mount_filesystem("/a/d", fsstub.ifilesystem());

    try std.testing.expect(sut.root != null);
    try std.testing.expectEqual(3, sut.root.?.children.len);

    try std.testing.expectEqual(0, sut.root.?.children.first.?.data.children.len);
    try std.testing.expectEqual(0, sut.root.?.children.first.?.next.?.data.children.len);
    try std.testing.expectEqual(0, sut.root.?.children.last.?.data.children.len);

    try std.testing.expectEqualStrings("a/b", sut.root.?.children.first.?.data.path);
    try std.testing.expectEqualStrings("a/c", sut.root.?.children.first.?.next.?.data.path);
    try std.testing.expectEqualStrings("a/d", sut.root.?.children.last.?.data.path);

    try sut.mount_filesystem("/a/c/a/c/", fsstub.ifilesystem());

    try std.testing.expect(sut.root != null);
    try std.testing.expectEqual(3, sut.root.?.children.len);

    try std.testing.expectEqual(0, sut.root.?.children.first.?.data.children.len);
    try std.testing.expectEqual(1, sut.root.?.children.first.?.next.?.data.children.len);
    try std.testing.expectEqual(0, sut.root.?.children.last.?.data.children.len);
    try std.testing.expectEqual(0, sut.root.?.children.first.?.next.?.data.children.first.?.data.children.len);

    try std.testing.expectEqualStrings("a/b", sut.root.?.children.first.?.data.path);
    try std.testing.expectEqualStrings("a/c", sut.root.?.children.first.?.next.?.data.children.first.?.data.path);
    try std.testing.expectEqualStrings("a/d", sut.root.?.children.last.?.data.path);

    try sut.mount_filesystem("/a/c/a/c/e", fsstub.ifilesystem());

    try std.testing.expect(sut.root != null);
    try std.testing.expectEqual(3, sut.root.?.children.len);

    try std.testing.expectEqual(0, sut.root.?.children.first.?.data.children.len);
    try std.testing.expectEqual(1, sut.root.?.children.first.?.next.?.data.children.len);
    try std.testing.expectEqual(0, sut.root.?.children.last.?.data.children.len);
    try std.testing.expectEqual(1, sut.root.?.children.first.?.next.?.data.children.first.?.data.children.len);

    try std.testing.expectEqualStrings("a/c", sut.root.?.children.first.?.next.?.data.path);
    try std.testing.expectEqualStrings("a/c", sut.root.?.children.first.?.next.?.data.children.first.?.data.path);
    try std.testing.expectEqualStrings("e", sut.root.?.children.first.?.next.?.data.children.first.?.data.children.first.?.data.path);

    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/b", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c/a/c", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c/a/c/e", fsstub.ifilesystem()));
}

test "report error when trying to mount relative path" {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = allocator.allocator();
    var sut = MountPoints.init(gpa);
    var fsstub = FileSystemStub{};
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expectError(MountPointError.MountPointNotAbsolutePath, sut.mount_filesystem("otherfs/smth", fsstub.ifilesystem()));
    try std.testing.expectError(MountPointError.MountPointNotAbsolutePath, sut.mount_filesystem("", fsstub.ifilesystem()));
}

test "handle not existing path" {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = allocator.allocator();
    var sut = MountPoints.init(gpa);
    var fsstub = FileSystemStub{ .has_file = false };
    try sut.mount_filesystem("/", fsstub.ifilesystem());
    try std.testing.expectError(MountPointError.PathNotExists, sut.mount_filesystem("/a/c", fsstub.ifilesystem()));
    fsstub.has_file = true;
    try sut.mount_filesystem("/a/c", fsstub.ifilesystem());
    fsstub.has_file = false;
    try std.testing.expectError(MountPointError.PathNotExists, sut.mount_filesystem("/a/c/d", fsstub.ifilesystem()));
}
