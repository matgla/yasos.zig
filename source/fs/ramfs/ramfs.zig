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

const IFileSystem = kernel.fs.IFileSystem;
const IDirectoryIterator = kernel.fs.IDirectoryIterator;
const IFile = kernel.fs.IFile;
const FileType = kernel.fs.FileType;

const std = @import("std");

const log = kernel.log;

const interface = @import("interface");

const RamFsFile = @import("ramfs_file.zig").RamFsFile;
const RamFsData = @import("ramfs_data.zig").RamFsData;

pub const RamFs = struct {
    pub usingnamespace interface.DeriveFromBase(IFileSystem, RamFs);
    allocator: std.mem.Allocator,
    root: FilesNode,

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

    pub fn init(allocator: std.mem.Allocator) !RamFs {
        return .{
            .allocator = allocator,
            .root = .{
                .node = try RamFsData.create_directory(allocator, "/"),
                .children = .{},
                .list_node = .{},
            },
        };
    }

    pub fn iterator(self: *RamFs, path: []const u8) ?IDirectoryIterator {
        _ = self;
        _ = path;
        return null;
    }

    pub fn mount(self: *RamFs) i32 {
        _ = self;
        return 0;
    }

    pub fn delete(self: *RamFs) void {
        _ = self.umount();
    }

    pub fn umount(self: *RamFs) i32 {
        self.root.deinit(self.allocator);
        return 0;
    }

    pub fn create(self: *RamFs, path: []const u8, _: i32, allocator: std.mem.Allocator) ?IFile {
        if (self.create_node(path, FileType.File)) |node| {
            return RamFsFile.create(&node.node, allocator).new(allocator) catch |err| {
                kernel.log.err("RamFs: Failed to create file at path: {s}, with an error: {s}\n", .{ path, @errorName(err) });
                return null;
            };
        }
        return null;
    }

    pub fn mkdir(self: *RamFs, path: []const u8, _: i32) i32 {
        const maybe_node = self.create_node(path, FileType.Directory);
        if (maybe_node != null) {
            return 0;
        }
        return -1;
    }

    pub fn remove(self: *RamFs, path: []const u8) i32 {
        var dirname = std.fs.path.dirname(path);
        const basename = std.fs.path.basenamePosix(path);
        if (dirname == null) {
            dirname = "/";
        }
        const maybe_parent = RamFs.get_node(*RamFs, self, dirname.?) catch return -1;
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

    pub fn name(self: *const RamFs) []const u8 {
        _ = self;
        return "ramfs";
    }

    pub fn traverse(self: *RamFs, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
        const maybe_node = RamFs.get_node(*RamFs, self, path) catch return -1;
        if (maybe_node) |file_node| {
            if (file_node.node.type == FileType.Directory) {
                var next = file_node.children.first;
                while (next) |node| {
                    const child: *FilesNode = @fieldParentPtr("list_node", node);
                    next = node.next;
                    var file: RamFsFile = RamFsFile.create(&child.node, self.allocator);
                    var ifile = file.interface();
                    if (!callback(&ifile, user_context)) {
                        return 0;
                    }
                }
                return 0;
            }
        }
        return -1;
    }

    pub fn get(self: *RamFs, path: []const u8, allocator: std.mem.Allocator) ?IFile {
        const maybe_node = RamFs.get_node(*RamFs, self, path) catch return null;
        if (maybe_node) |node| {
            return RamFsFile.create(&node.node, allocator).new(allocator) catch |err| {
                kernel.log.err("RamFs: Failed to create file at path: {s}, with an error: {s}\n", .{ path, @errorName(err) });
                return null;
            };
        }
        return null;
    }

    pub fn has_path(self: *const RamFs, path: []const u8) bool {
        const node = RamFs.get_node(*const RamFs, self, path) catch return false;
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

    fn create_node(self: *RamFs, path: []const u8, filetype: FileType) ?*FilesNode {
        var dirname = std.fs.path.dirname(path);
        const basename = std.fs.path.basenamePosix(path);
        if (dirname == null) {
            dirname = "/";
        }
        if (dirname) |parent_path| {
            const maybe_parent_node = RamFs.get_node(*RamFs, self, parent_path) catch return null;
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
                parent_node.children.append(&new.list_node);
                return new;
            }
        }
        return null;
    }
};

const ExpectationList = std.ArrayList([]const u8);
var expected_directories: ExpectationList = undefined;
var did_error: anyerror!void = {};

fn traverse_dir(file: *IFile, _: *anyopaque) bool {
    const name = file.name().get_name();
    did_error catch return false;

    const maybe_expectation = expected_directories.pop();
    if (maybe_expectation) |expectation| {
        did_error = std.testing.expectEqualStrings(expectation, name);
        did_error catch {
            std.debug.print("Expectation not matched, expected: '{s}', found: '{s}'\n", .{ expectation, name });
            return false;
        };
    } else {
        std.debug.print("Expectation not found for: '{s}'\n", .{name});
        return false;
    }
    return true;
}

test "Create files in ramfs" {
    expected_directories = ExpectationList.init(std.testing.allocator);
    defer expected_directories.deinit();
    var fs = try RamFs.init(std.testing.allocator);
    var sut = fs.interface();
    defer _ = sut.umount();

    try std.testing.expectEqualStrings("ramfs", sut.name());
    try std.testing.expectEqual(0, sut.mkdir("/test", 0));
    try std.testing.expectEqual(0, sut.mkdir("/test/dir", 0));
    try std.testing.expectEqual(0, sut.mkdir("test/dir/nested", 0));
    try std.testing.expectEqual(0, sut.mkdir("other", 0));
    try std.testing.expectEqual(-1, sut.mkdir("/test/dir", 0));

    try std.testing.expectEqual(-1, sut.mkdir("nonexisting/dir/nested", 0));

    try std.testing.expectEqual(false, sut.has_path("other2"));
    try std.testing.expectEqual(true, sut.has_path("/"));
    try std.testing.expectEqual(true, sut.has_path("/test"));
    try std.testing.expectEqual(true, sut.has_path("/test/dir"));
    try std.testing.expectEqual(true, sut.has_path("/test/dir/nested"));
    try std.testing.expectEqual(true, sut.has_path("/other"));
    try std.testing.expectEqual(true, sut.has_path("test"));
    try std.testing.expectEqual(true, sut.has_path("test/dir"));
    try std.testing.expectEqual(true, sut.has_path("test/dir/nested"));
    try std.testing.expectEqual(true, sut.has_path("other"));

    var maybe_file = sut.create("/test/file.txt", 0, std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        file.delete();
    }

    try std.testing.expectEqual(null, sut.create("/test/file.txt", 0, std.testing.allocator));

    maybe_file = sut.create("test/dir/nested/file", 0, std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        file.delete();
    }

    try std.testing.expectEqual(true, sut.has_path("/test/file.txt"));
    try std.testing.expectEqual(true, sut.has_path("/test/dir/nested/file"));

    try expected_directories.insert(0, "test");
    try expected_directories.insert(0, "other");

    try std.testing.expectEqual(-1, sut.traverse("/test/file.txt", traverse_dir, undefined));
    try std.testing.expectEqual(0, sut.traverse("/", traverse_dir, undefined));
    try did_error;
    try std.testing.expectEqual(0, expected_directories.items.len);

    try expected_directories.insert(0, "dir");
    try expected_directories.insert(0, "file.txt");

    try std.testing.expectEqual(0, sut.traverse("/test", traverse_dir, undefined));
    try did_error;
    try std.testing.expectEqual(0, expected_directories.items.len);

    // reject non empty directory removal
    try std.testing.expectEqual(-1, sut.remove("/test"));
    maybe_file = sut.get("/test/file.txt", std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        defer file.delete();
        try std.testing.expectEqual(18, file.write("Some data for file"));
    }

    try std.testing.expectEqual(0, sut.remove("/test/file.txt"));
    try std.testing.expectEqual(false, sut.has_path("/test/file.txt"));
    try std.testing.expectEqual(0, sut.remove("/test/dir/nested/file"));
    try std.testing.expectEqual(0, sut.remove("/test/dir/nested"));
    try std.testing.expectEqual(0, sut.remove("/test/dir"));
    try std.testing.expectEqual(0, sut.remove("/test"));
}
