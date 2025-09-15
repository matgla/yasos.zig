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

const FilesNode = struct {
    node: RamFsData,
    children: std.DoublyLinkedList,
    list_node: std.DoublyLinkedList.Node,

    pub fn deinit(self: *FilesNode, allocator: std.mem.Allocator) void {
        var next = self.children.pop();

        while (next) |node| {
            const child: *FilesNode = @fieldParentPtr("list_node", node);
            next = self.children.pop();
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.node.deinit();
    }

    pub fn get(self: *const FilesNode, node_name: []const u8) ?*FilesNode {
        var next = self.children.first;
        while (next) |node| {
            const child: *FilesNode = @fieldParentPtr("list_node", node);
            next = node.next;
            if (std.mem.eql(u8, child.node.name(), node_name)) {
                return child;
            }
        }
        return null;
    }
};

const RamFsIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _current: ?*std.DoublyLinkedList.Node,

    pub fn create(data: *std.DoublyLinkedList, allocator: std.mem.Allocator) RamFsIterator {
        return RamFsIterator.init(.{
            ._allocator = allocator,
            ._current = data.first,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.INode {
        if (self._current) |current| {
            const file = RamFsNode.InstanceType.create(self._allocator, &(@as(*FilesNode, @fieldParentPtr("list_node", current))).node);
            self._current = current.next;
            return file.interface.new(self._allocator) catch |err| {
                log.err("RamFs: Failed to create file from iterator: {s}", .{@errorName(err)});
                return null;
            };
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

pub const RamFs = interface.DeriveFromBase(IFileSystem, struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    root: FilesNode,

    pub fn init(allocator: std.mem.Allocator) !RamFs {
        return RamFs.init(.{
            .allocator = allocator,
            .root = FilesNode{
                .node = try RamFsData.create_directory(allocator, "/"),
                .children = .{},
                .list_node = .{},
            },
        });
    }

    pub fn iterator(self: *Self, path: []const u8) ?IDirectoryIterator {
        _ = path;
        return RamFsIterator.InstanceType.create(&self.root.children, self.allocator).interface.new(self.allocator) catch {
            return null;
        };
    }

    pub fn mount(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self.umount();
    }

    pub fn umount(self: *Self) i32 {
        self.root.deinit(self.allocator);
        return 0;
    }

    pub fn create(self: *Self, path: []const u8, _: i32, allocator: std.mem.Allocator) ?IFile {
        if (self.create_node(path, FileType.File)) |node| {
            log.info("Creating file at path: {s}", .{path});
            return RamFsFile.InstanceType.create(&node.node, allocator).interface.new(allocator) catch |err| {
                kernel.log.err("RamFs: Failed to create file at path: {s}, with an error: {s}\n", .{ path, @errorName(err) });
                return null;
            };
        } else {
            kernel.log.err("RamFs: Failed to create file at path: {s}, file already exists", .{path});
            return null;
        }
        return null;
    }

    pub fn mkdir(self: *Self, path: []const u8, _: i32) i32 {
        const maybe_node = self.create_node(path, FileType.Directory);
        if (maybe_node != null) {
            return 0;
        }
        return -1;
    }

    pub fn remove(self: *Self, path: []const u8) i32 {
        var dirname = std.fs.path.dirname(path);
        const basename = std.fs.path.basenamePosix(path);
        if (dirname == null) {
            dirname = "/";
        }
        const maybe_parent = Self.get_node(*Self, self, dirname.?) catch return -1;
        if (maybe_parent) |parent| {
            var next = parent.children.first;
            while (next) |node| {
                const child: *FilesNode = @fieldParentPtr("list_node", node);
                next = node.next;
                if (std.mem.eql(u8, child.node.name(), basename)) {
                    if (child.children.len() != 0) {
                        return -1;
                    }
                    parent.children.remove(&child.list_node);
                    child.deinit(self.allocator);
                    self.allocator.destroy(child);
                    return 0;
                }
            }
        }

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
        const maybe_node = Self.get_node(*Self, self, path) catch return -1;
        if (maybe_node) |node| {
            node.node.stat(data);
            return 0;
        }
        return -1;
    }

    pub fn traverse(self: *Self, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
        const maybe_node = Self.get_node(*Self, self, path) catch return -1;
        if (maybe_node) |file_node| {
            if (file_node.node.type == FileType.Directory) {
                var next = file_node.children.first;
                while (next) |node| {
                    const child: *FilesNode = @fieldParentPtr("list_node", node);
                    next = node.next;
                    var file: RamFsFile = RamFsFile.InstanceType.create(&child.node, self.allocator);
                    var ifile = file.interface.new(self.allocator) catch return -1;
                    defer ifile.interface.delete();
                    if (!callback(&ifile, user_context)) {
                        return 0;
                    }
                }
                return 0;
            }
        }
        return -1;
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?IFile {
        const maybe_node = Self.get_node(*Self, self, path) catch return null;
        if (maybe_node) |node| {
            return RamFsFile.InstanceType.create(&node.node, allocator).interface.new(allocator) catch |err| {
                kernel.log.err("RamFs: Failed to create file at path: {s}, with an error: {s}\n", .{ path, @errorName(err) });
                return null;
            };
        }
        return null;
    }

    pub fn has_path(self: *Self, path: []const u8) bool {
        const node = Self.get_node(*const Self, self, path) catch return false;
        return node != null;
    }

    fn determine_filesnode_type(comptime T: type) type {
        if (@typeInfo(T).pointer.is_const) {
            return *const FilesNode;
        }
        return *FilesNode;
    }

    fn get_node(comptime T: type, self: T, path: []const u8) !?determine_filesnode_type(T) {
        var it = try std.fs.path.componentIterator(path);
        var component = it.first();
        var node: determine_filesnode_type(T) = &self.root;
        while (component) |part| : (component = it.next()) {
            const maybe_node = node.get(part.name);
            if (maybe_node) |child| {
                node = child;
            } else {
                return null;
            }
        }
        return node;
    }

    fn create_node(self: *Self, path: []const u8, filetype: FileType) ?*FilesNode {
        var dirname = std.fs.path.dirname(path);
        const basename = std.fs.path.basenamePosix(path);
        if (dirname == null) {
            dirname = "/";
        }
        if (dirname) |parent_path| {
            const maybe_parent_node = Self.get_node(*Self, self, parent_path) catch return null;
            if (maybe_parent_node) |parent_node| {
                if (parent_node.get(basename) != null) {
                    return null;
                }
                var new: *FilesNode = self.allocator.create(FilesNode) catch return null;
                new.* = FilesNode{
                    .node = RamFsData.create(self.allocator, basename, filetype) catch return null,
                    .children = .{},
                    .list_node = .{},
                };
                log.info("Creating node at path: {s}", .{path});
                parent_node.children.append(&new.list_node);
                return new;
            }
        }
        return null;
    }
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
