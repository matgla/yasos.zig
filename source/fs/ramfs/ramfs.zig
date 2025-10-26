//
// ramfs.zig
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

const kernel = @import("kernel");

const c = @import("libc_imports").c;

const IFileSystem = kernel.fs.IFileSystem;
const IDirectoryIterator = kernel.fs.IDirectoryIterator;
const IFile = kernel.fs.IFile;
const FileType = kernel.fs.FileType;

const std = @import("std");

const log = kernel.log;

const interface = @import("interface");

const RamFsFile = @import("ramfs_file.zig").RamFsFile;
const RamFsData = @import("ramfs_data.zig").RamFsData;
const RamFsNode = @import("ramfs_node.zig").RamFsNode;

const RamFsDirectory = @import("ramfs_directory.zig").RamFsDirectory;

pub const RamFs = interface.DeriveFromBase(IFileSystem, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _root: kernel.fs.Node,

    pub fn init(allocator: std.mem.Allocator) !RamFs {
        return RamFs.init(.{
            ._allocator = allocator,
            ._root = try RamFsDirectory.InstanceType.create_node(allocator, "/"),
        });
    }

    pub fn mount(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self.umount();
    }

    pub fn umount(self: *Self) i32 {
        self._root.delete();
        return 0;
    }

    fn get_parent_node(self: *Self, path: []const u8) !kernel.fs.Node {
        const resolved_path = try std.fs.path.resolve(self._allocator, &.{path});
        defer self._allocator.free(resolved_path);
        const maybe_dirpath: ?[]const u8 = std.fs.path.dirname(resolved_path);

        if (maybe_dirpath) |dirpath| {
            return try self.get(dirpath);
        }
        return try self._root.clone();
    }

    pub fn create(self: *Self, path: []const u8, _: i32) anyerror!void {
        if (path.len == 0) {
            return kernel.errno.ErrnoSet.InvalidArgument;
        }
        var maybe_node: ?kernel.fs.Node = self.get(path) catch |err| blk: {
            if (err != kernel.errno.ErrnoSet.NoEntry) {
                return err;
            }
            break :blk null;
        };
        if (maybe_node) |*node| {
            node.delete();
            return kernel.errno.ErrnoSet.FileExists;
        }
        const basename = std.fs.path.basenamePosix(path);
        var parent_node = try self.get_parent_node(path);
        defer parent_node.delete();
        var maybe_parent_dir = parent_node.as_directory();
        if (maybe_parent_dir) |*parent_dir| {
            const filedata = try self._allocator.create(RamFsData);
            filedata.* = try RamFsData.create(self._allocator);
            const filenode = try self._allocator.create(RamFsNode);
            const filename = try self._allocator.dupe(u8, basename);
            filenode.* = RamFsNode{
                .node = try RamFsFile.InstanceType.create_node(self._allocator, filedata, filename),
                .list_node = std.DoublyLinkedList.Node{},
                .name = filename,
            };
            try parent_dir.as(RamFsDirectory).data().append(filenode);
            return;
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn mkdir(self: *Self, path: []const u8, _: i32) anyerror!void {
        if (path.len == 0) {
            return kernel.errno.ErrnoSet.InvalidArgument;
        }
        var maybe_node = self.get(path) catch |err| blk: {
            if (err != kernel.errno.ErrnoSet.NoEntry) {
                return err;
            }
            break :blk null;
        };
        if (maybe_node) |*node| {
            node.delete();
            return kernel.errno.ErrnoSet.FileExists;
        }
        const basename = std.fs.path.basenamePosix(path);
        var parent_node = try self.get_parent_node(path);
        defer parent_node.delete();
        var maybe_parent_dir = parent_node.as_directory();
        if (maybe_parent_dir) |*parent_dir| {
            const node = try self._allocator.create(RamFsNode);
            const dirname = try self._allocator.dupe(u8, basename);
            node.* = RamFsNode{
                .node = try RamFsDirectory.InstanceType.create_node(self._allocator, dirname),
                .list_node = std.DoublyLinkedList.Node{},
                .name = dirname,
            };
            try parent_dir.as(RamFsDirectory).data().append(node);
            return;
        } else {
            return kernel.errno.ErrnoSet.NotADirectory;
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        var node = try self.get(path);
        defer node.delete();
        const nodename = std.fs.path.basename(path);
        var parent_node = try self.get_parent_node(path);
        defer parent_node.delete();
        var maybe_directory = parent_node.as_directory();
        if (maybe_directory) |*parent_dir| {
            try parent_dir.as(RamFsDirectory).data().unlink(nodename);
            return;
        } else {
            return kernel.errno.ErrnoSet.NotADirectory;
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "ramfs";
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self.umount();
        self._root = try RamFsDirectory.InstanceType.create_node(self._allocator, "/");
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat) anyerror!void {
        var node = try self.get(path);
        defer node.delete();
        data.st_mode = switch (node.filetype()) {
            .File => c.S_IFREG,
            .Directory => c.S_IFDIR,
            else => return,
        };
        return;
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return try self._root.clone();
        }

        const resolved_path = try std.fs.path.resolve(self._allocator, &.{path});
        defer self._allocator.free(resolved_path);

        var it = try std.fs.path.componentIterator(resolved_path);
        var current_directory: kernel.fs.IDirectory = self._root.as_directory().?;
        while (it.next()) |component| {
            if (it.peekNext() != null) {
                // Intermediate component, must be a directory
                var next_node: kernel.fs.Node = undefined;
                try current_directory.interface.get(component.name, &next_node);
                defer next_node.delete();
                if (next_node.filetype() != FileType.Directory) {
                    return kernel.errno.ErrnoSet.NoEntry;
                }
                current_directory = next_node.as_directory().?;
            } else {
                // Last component, can be file or directory
                var next_node: kernel.fs.Node = undefined;
                try current_directory.interface.get(component.name, &next_node);
                return next_node;
            }
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        var node = try self.get(old_path);
        defer node.delete();
        if (node.filetype() == FileType.Directory) {
            return kernel.errno.ErrnoSet.IsADirectory;
        }

        var parent_node = try self.get_parent_node(new_path);
        defer parent_node.delete();
        var maybe_parent_dir = parent_node.as_directory();
        if (maybe_parent_dir) |*parent_dir| {
            const filename = try self._allocator.dupe(u8, std.fs.path.basename(new_path));
            const new_node = try self._allocator.create(RamFsNode);
            var file = node.as_file().?;
            const new_file = try RamFsFile.InstanceType.create_node(
                self._allocator,
                file.as(RamFsFile).data()._data.share(),
                filename,
            );

            new_node.* = RamFsNode{
                .node = new_file,
                .list_node = std.DoublyLinkedList.Node{},
                .name = filename,
            };
            try parent_dir.as(RamFsDirectory).data().append(new_node);
            return;
        }
        return kernel.errno.ErrnoSet.NotADirectory;
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        _ = flags;
        var n = try self.get(path);
        defer n.delete();

        if ((mode & c.W_OK) != 0 or (mode & c.X_OK) != 0) {
            if (n.filetype() == FileType.Directory) {
                return kernel.errno.ErrnoSet.IsADirectory;
            }
        }
    }
});

fn has_path(sut: *kernel.fs.IFileSystem, path: []const u8) bool {
    var node = sut.interface.get(path) catch return false;
    defer node.delete();
    return true;
}

test "RamFsFile.ShouldCreateAndRemoveFiles" {
    const verify_directory_content = @import("../tests/directory_traverser.zig").verify_directory_content;
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try std.testing.expectEqualStrings("ramfs", sut.interface.name());
    try sut.interface.mkdir("/test", 0);
    try sut.interface.mkdir("/test/dir", 0);
    try sut.interface.mkdir("test/dir/nested", 0);
    try sut.interface.mkdir("other", 0);

    try std.testing.expectError(kernel.errno.ErrnoSet.FileExists, sut.interface.mkdir("/test/dir", 0));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NoEntry, sut.interface.mkdir("nonexisting/dir/nested", 0));

    try std.testing.expect(!has_path(&sut, "other2"));
    try std.testing.expect(has_path(&sut, "/"));
    try std.testing.expect(has_path(&sut, "/test"));
    try std.testing.expect(has_path(&sut, "/test/dir"));
    try std.testing.expect(has_path(&sut, "/test/dir/nested"));
    try std.testing.expect(has_path(&sut, "/other"));
    try std.testing.expect(has_path(&sut, "test"));
    try std.testing.expect(has_path(&sut, "test/dir"));
    try std.testing.expect(has_path(&sut, "test/dir/nested"));
    try std.testing.expect(has_path(&sut, "other"));

    try sut.interface.create("/test/file.txt", 0);
    try std.testing.expectError(kernel.errno.ErrnoSet.FileExists, sut.interface.create("/test/file.txt", 0));

    try sut.interface.create("test/dir/nested/file", 0);
    try std.testing.expect(has_path(&sut, "/test/file.txt"));
    try std.testing.expect(has_path(&sut, "/test/dir/nested/file"));

    try verify_directory_content(&sut, "/test", &.{
        .{ .name = "file.txt", .kind = .File },
        .{ .name = "dir", .kind = .Directory },
    });

    try verify_directory_content(&sut, "/", &.{
        .{ .name = "test", .kind = .Directory },
        .{ .name = "other", .kind = .Directory },
    });

    try verify_directory_content(&sut, "/test/dir", &.{
        .{ .name = "nested", .kind = .Directory },
    });

    // reject non empty directory removal
    try std.testing.expectError(kernel.errno.ErrnoSet.DeviceOrResourceBusy, sut.interface.unlink("/test"));
    var node = try sut.interface.get("/test/file.txt");
    var file = node.as_file();
    try std.testing.expect(file != null);
    try std.testing.expectEqual(18, file.?.interface.write("Some data for file"));
    node.delete();

    try sut.interface.unlink("/test/file.txt");
    try std.testing.expect(!has_path(&sut, "/test/file.txt"));
    try sut.interface.unlink("/test/dir/nested/file");
    try sut.interface.unlink("/test/dir/nested");
    try sut.interface.unlink("/test/dir");
    try sut.interface.unlink("/test");
}

test "RamFs.ShouldCreateLink" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try std.testing.expectEqualStrings("ramfs", sut.interface.name());
    try sut.interface.mkdir("/dir", 0);

    try sut.interface.create("/dir/file.txt", 0);
    var node = try sut.interface.get("/dir/file.txt");
    defer node.delete();
    var file = node.as_file();
    try std.testing.expect(file != null);
    try std.testing.expectEqual(18, file.?.interface.write("Some data for file"));

    try std.testing.expect(has_path(&sut, "/dir/file.txt"));
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.interface.link("/dir/file2.txt", "/dir/file_link.txt"));
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, sut.interface.link("/dir", "/dir/file_link"));
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.interface.link("/dir/file.txt", "/dir2/file_link.txt"));

    try sut.interface.link("/dir/file.txt", "/dir/file_link.txt");
    var link_node = try sut.interface.get("/dir/file_link.txt");
    defer link_node.delete();

    var link_file = link_node.as_file();
    try std.testing.expect(link_file != null);

    var buffer: [40]u8 = undefined;
    try std.testing.expectEqual(18, link_file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("Some data for file", buffer[0..18]);
    try std.testing.expectEqual(10, link_file.?.interface.write(" More data"));

    try std.testing.expect(file != null);
    _ = try file.?.interface.seek(0, c.SEEK_SET);
    try std.testing.expectEqual(28, file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("Some data for file More data", buffer[0..28]);

    try sut.interface.unlink("/dir/file.txt");
    try std.testing.expect(!has_path(&sut, "/dir/file.txt"));

    _ = try link_file.?.interface.seek(0, c.SEEK_SET);
    try std.testing.expectEqual(28, link_file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("Some data for file More data", buffer[0..28]);
}

test "RamFs.ShouldFormat" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try std.testing.expectEqualStrings("ramfs", sut.interface.name());
    try sut.interface.mkdir("/test", 0);
    try sut.interface.mkdir("/test/dir", 0);

    try std.testing.expect(has_path(&sut, "/test"));
    try std.testing.expect(has_path(&sut, "/test/dir"));

    try sut.interface.format();

    try std.testing.expect(!has_path(&sut, "/test"));
    try std.testing.expect(!has_path(&sut, "/test/dir"));
}

test "RamFs.StatShouldWork" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    var stat_data: c.struct_stat = undefined;

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.interface.stat("/nonexisting", &stat_data));

    try sut.interface.mkdir("/test", 0);
    try sut.interface.stat("/test", &stat_data);
    try std.testing.expectEqual(c.S_IFDIR, stat_data.st_mode);

    try sut.interface.create("/test/file.txt", 0);
    try sut.interface.stat("/test/file.txt", &stat_data);
    try std.testing.expectEqual(c.S_IFREG, stat_data.st_mode);
}

test "RamFs.AccessShouldWork" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.interface.access("/nonexisting", c.F_OK, 0));

    try sut.interface.mkdir("/test", 0);
    try sut.interface.access("/test", c.F_OK, 0);
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, sut.interface.access("/test", c.W_OK, 0));

    try sut.interface.create("/test/file.txt", 0);
    try sut.interface.access("/test/file.txt", c.F_OK, 0);
    try sut.interface.access("/test/file.txt", c.W_OK, 0);
}

test "RamFsFile.ShouldWriteAndReadData" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try sut.interface.create("/file.txt", 0);
    var node = try sut.interface.get("/file.txt");
    defer node.delete();
    var file = node.as_file();
    try std.testing.expect(file != null);

    try std.testing.expectEqual(18, file.?.interface.write("Some data for file"));

    var buffer: [32]u8 = undefined;
    _ = try file.?.interface.seek(0, c.SEEK_SET);
    try std.testing.expectEqual(18, file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("Some data for file", buffer[0..18]);
}

test "RamFsFile.ShouldHandleSeekCorrectly" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try sut.interface.create("/file.txt", 0);
    var node = try sut.interface.get("/file.txt");
    defer node.delete();
    var file = node.as_file();
    try std.testing.expect(file != null);

    try std.testing.expectEqual(11, file.?.interface.write("Hello World"));

    var buffer: [32]u8 = undefined;
    _ = try file.?.interface.seek(-5, c.SEEK_END);
    try std.testing.expectEqual(5, file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("World", buffer[0..5]);

    _ = try file.?.interface.seek(6, c.SEEK_SET);
    try std.testing.expectEqual(5, file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("World", buffer[0..5]);

    _ = try file.?.interface.seek(-11, c.SEEK_CUR);
    try std.testing.expectEqual(11, file.?.interface.read(buffer[0..11]));
    try std.testing.expectEqualStrings("Hello World", buffer[0..11]);
}
