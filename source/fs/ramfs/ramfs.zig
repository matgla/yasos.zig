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

    pub fn create(self: *Self, path: []const u8, _: i32, allocator: std.mem.Allocator) ?kernel.fs.Node {
        _ = allocator;
        const resolved_path = std.fs.path.resolve(self._allocator, &.{path}) catch return null;
        defer self._allocator.free(resolved_path);
        if (resolved_path.len == 0 or std.mem.eql(u8, resolved_path, "/")) {
            return null;
        }
        const basename = std.fs.path.basenamePosix(resolved_path);
        const maybe_dirpath: ?[]const u8 = std.fs.path.dirname(resolved_path);
        var maybe_parent_node: ?kernel.fs.Node = null;

        if (maybe_dirpath) |dirpath| {
            maybe_parent_node = self.get(dirpath, self._allocator) orelse return null;
        } else {
            maybe_parent_node = self._root.clone() catch return null;
        }
        if (maybe_parent_node) |*parent_node| {
            defer parent_node.delete();
            var maybe_parent_dir = parent_node.as_directory();
            if (maybe_parent_dir) |*parent_dir| {
                const filedata = self._allocator.create(RamFsData) catch return null;
                filedata.* = RamFsData.create(self._allocator, basename) catch return null;
                const new_file = RamFsFile.InstanceType.create_node(self._allocator, filedata) catch return null;
                parent_dir.as(RamFsDirectory).data().append(new_file) catch return null;
                return new_file.clone() catch return null;
            }
        }
        return null;
    }

    pub fn mkdir(self: *Self, path: []const u8, _: i32) i32 {
        _ = self;
        _ = path;

        // const maybe_node = self.create_directory(path, FileType.Directory);
        // if (maybe_node != null) {
        //     return 0;
        // }
        return -1;
    }

    pub fn remove(self: *Self, path: []const u8) i32 {
        _ = self;
        _ = path;
        // var dirname = std.fs.path.dirname(path);
        // const basename = std.fs.path.basenamePosix(path);
        // if (dirname == null) {
        //     dirname = "/";
        // }
        // const maybe_parent = Self.get_node(*Self, self, dirname.?) catch return -1;
        // if (maybe_parent) |parent| {
        //     var next = parent.children.first;
        //     while (next) |node| {
        //         const child: *FilesNode = @fieldParentPtr("list_node", node);
        //         next = node.next;
        //         if (std.mem.eql(u8, child.node.name(), basename)) {
        //             if (child.children.len() != 0) {
        //                 return -1;
        //             }
        //             parent.children.remove(&child.list_node);
        //             child.deinit(self.allocator);
        //             self.allocator.destroy(child);
        //             return 0;
        //         }
        //     }
        // }

        return -1;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "ramfs";
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self;
        // RamFS is a memory-based filesystem, so formatting is not applicable
        return error.NotSupported;
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat) i32 {
        var maybe_node = self.get(path, self._allocator);
        if (maybe_node) |*node| {
            defer node.delete();
            data.st_mode = switch (node.filetype()) {
                .File => c.S_IFREG,
                .Directory => c.S_IFDIR,
                else => 0,
            };
            return 0;
        }
        return -1;
    }

    pub fn traverse(self: *Self, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
        // const maybe_node = Self.get_node(*Self, self, path) catch return -1;
        // if (maybe_node) |file_node| {
        //     if (file_node.node.type == FileType.Directory) {
        //         var next = file_node.children.first;
        //         while (next) |node| {
        //             const child: *FilesNode = @fieldParentPtr("list_node", node);
        //             next = node.next;
        //             var file: RamFsFile = RamFsFile.InstanceType.create(self.allocator, &child.node);
        //             var ifile = file.interface.new(self.allocator) catch return -1;
        //             defer ifile.interface.delete();
        //             if (!callback(&ifile, user_context)) {
        //                 return 0;
        //             }
        //         }
        //         return 0;
        //     }
        // }
        _ = self;
        _ = path;
        _ = callback;
        _ = user_context;
        return -1;
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?kernel.fs.Node {
        _ = allocator;

        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return self._root.clone() catch return null;
        }

        const resolved_path = std.fs.path.resolve(self._allocator, &.{path}) catch return null;
        defer self._allocator.free(resolved_path);

        var it = try std.fs.path.componentIterator(resolved_path);
        var current_directory: kernel.fs.IDirectory = self._root.as_directory().?;
        while (it.next()) |component| {
            if (it.peekNext() != null) {
                // Intermediate component, must be a directory
                var next_node: kernel.fs.Node = undefined;
                current_directory.interface.get(component.name, &next_node) catch return null;
                defer next_node.delete();
                if (next_node.filetype() != FileType.Directory) {
                    return null;
                }
                current_directory = next_node.as_directory().?;
            } else {
                // Last component, can be file or directory
                var next_node: kernel.fs.Node = undefined;
                current_directory.interface.get(component.name, &next_node) catch return null;
                return next_node;
            }
        }
        return null;
    }

    pub fn has_path(self: *Self, path: []const u8) bool {
        var node = self.get(path, self._allocator) orelse return false;
        defer node.delete();
        return true;
    }

    // fn create_node(self: *Self, path: []const u8, filetype: FileType) ?*FilesNode {
    //     var dirname = std.fs.path.dirname(path);
    //     const basename = std.fs.path.basenamePosix(path);
    //     if (dirname == null) {
    //         dirname = "/";
    //     }
    //     if (dirname) |parent_path| {
    //         const maybe_parent_node = Self.get_node(*Self, self, parent_path) catch return null;
    //         if (maybe_parent_node) |parent_node| {
    //             if (parent_node.get(basename) != null) {
    //                 return null;
    //             }
    //             var new: *FilesNode = self.allocator.create(FilesNode) catch return null;
    //             new.* = FilesNode{
    //                 .node = RamFsData.create(self.allocator, basename, filetype) catch return null,
    //                 .children = .{},
    //                 .list_node = .{},
    //             };
    //             log.info("Creating node at path: {s}", .{path});
    //             parent_node.children.append(&new.list_node);
    //             return new;
    //         }
    //     }
    //     return null;
    // }
});

test "RomFsFile.ShouldCreateAndRemoveFiles" {
    const TestDirectoryTraverser = @import("../tests/directory_traverser.zig").TestDirectoryTraverser;
    try TestDirectoryTraverser.init(std.testing.allocator);
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.umount();

    try std.testing.expectEqualStrings("ramfs", sut.interface.name());
    try std.testing.expectEqual(0, sut.interface.mkdir("/test", 0));
    try std.testing.expectEqual(0, sut.interface.mkdir("/test/dir", 0));
    try std.testing.expectEqual(0, sut.interface.mkdir("test/dir/nested", 0));
    try std.testing.expectEqual(0, sut.interface.mkdir("other", 0));
    try std.testing.expectEqual(-1, sut.interface.mkdir("/test/dir", 0));

    try std.testing.expectEqual(-1, sut.interface.mkdir("nonexisting/dir/nested", 0));

    try std.testing.expectEqual(false, sut.interface.has_path("other2"));
    try std.testing.expectEqual(true, sut.interface.has_path("/"));
    try std.testing.expectEqual(true, sut.interface.has_path("/test"));
    try std.testing.expectEqual(true, sut.interface.has_path("/test/dir"));
    try std.testing.expectEqual(true, sut.interface.has_path("/test/dir/nested"));
    try std.testing.expectEqual(true, sut.interface.has_path("/other"));
    try std.testing.expectEqual(true, sut.interface.has_path("test"));
    try std.testing.expectEqual(true, sut.interface.has_path("test/dir"));
    try std.testing.expectEqual(true, sut.interface.has_path("test/dir/nested"));
    try std.testing.expectEqual(true, sut.interface.has_path("other"));

    var maybe_file = sut.interface.create("/test/file.txt", 0, std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        file.interface.delete();
    }

    try std.testing.expectEqual(null, sut.interface.create("/test/file.txt", 0, std.testing.allocator));

    maybe_file = sut.interface.create("test/dir/nested/file", 0, std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        file.interface.delete();
    }

    try std.testing.expectEqual(true, sut.interface.has_path("/test/file.txt"));
    try std.testing.expectEqual(true, sut.interface.has_path("/test/dir/nested/file"));

    try TestDirectoryTraverser.append("test");
    try TestDirectoryTraverser.append("other");

    try std.testing.expectEqual(-1, sut.interface.traverse("/test/file.txt", TestDirectoryTraverser.traverse_dir, undefined));
    try std.testing.expectEqual(0, sut.interface.traverse("/", TestDirectoryTraverser.traverse_dir, undefined));
    try TestDirectoryTraverser.did_error;
    try std.testing.expectEqual(0, TestDirectoryTraverser.size());

    try TestDirectoryTraverser.append("dir");
    try TestDirectoryTraverser.append("file.txt");

    try std.testing.expectEqual(0, sut.interface.traverse("/test", TestDirectoryTraverser.traverse_dir, undefined));
    try TestDirectoryTraverser.did_error;
    try std.testing.expectEqual(0, TestDirectoryTraverser.size());

    // reject non empty directory removal
    try std.testing.expectEqual(-1, sut.interface.remove("/test"));
    maybe_file = sut.interface.get("/test/file.txt", std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        defer file.interface.delete();
        try std.testing.expectEqual(18, file.interface.write("Some data for file"));
    }

    try std.testing.expectEqual(0, sut.interface.remove("/test/file.txt"));
    try std.testing.expectEqual(false, sut.interface.has_path("/test/file.txt"));
    try std.testing.expectEqual(0, sut.interface.remove("/test/dir/nested/file"));
    try std.testing.expectEqual(0, sut.interface.remove("/test/dir/nested"));
    try std.testing.expectEqual(0, sut.interface.remove("/test/dir"));
    try std.testing.expectEqual(0, sut.interface.remove("/test"));

    try TestDirectoryTraverser.deinit();
}
