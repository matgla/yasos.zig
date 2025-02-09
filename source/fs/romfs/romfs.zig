//
// romfs.zig
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

const IFileSystem = @import("../../kernel/fs/fs.zig").IFileSystem;
const IFile = @import("../../kernel/fs/fs.zig").IFile;
const FileType = @import("../../kernel/fs/ifile.zig").FileType;

const RomFsFile = @import("romfs_file.zig").RomFsFile;

const FileSystemHeader = @import("file_system_header.zig").FileSystemHeader;
const FileHeader = @import("file_header.zig").FileHeader;

const std = @import("std");

const log = &@import("../../log/kernel_log.zig").kernel_log;

pub const RomFs = struct {
    root: FileSystemHeader,
    allocator: std.mem.Allocator,

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

    pub fn init(allocator: std.mem.Allocator, memory: []const u8) ?RomFs {
        const fs = FileSystemHeader.init(memory);
        if (fs) |root| {
            return .{
                .root = root,
                .allocator = allocator,
            };
        }
        return null;
    }

    pub fn ifilesystem(self: *RomFs) IFileSystem {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    fn mount(_: *anyopaque) i32 {
        // nothing to do
        return 0;
    }

    fn umount(_: *anyopaque) i32 {
        // nothing to do
        return 0;
    }

    fn create(_: *anyopaque, _: []const u8, _: i32) i32 {
        // read-only filesystem
        return -1;
    }

    fn mkdir(_: *anyopaque, _: []const u8, _: i32) i32 {
        // read-only filesystem
        return -1;
    }

    fn remove(_: *anyopaque, _: []const u8) i32 {
        // read-only filesystem
        return -1;
    }

    fn name(_: *const anyopaque) []const u8 {
        return "romfs";
    }

    fn traverse(ctx: *anyopaque, path: []const u8, callback: *const fn (file: *IFile) void) i32 {
        const self: *RomFs = @ptrCast(@alignCast(ctx));
        const maybe_node = self.get_file_header(path);
        if (maybe_node) |node| {
            if (node.filetype() == FileType.Directory) {
                var it: ?FileHeader = FileHeader.init(node.memory, node.specinfo());
                while (it) |child| : (it = child.next()) {
                    var file: RomFsFile = RomFsFile.init(child);
                    var ifile = file.ifile();
                    callback(&ifile);
                }
                return 0;
            } else if (node.filetype() == FileType.SymbolicLink) {
                std.debug.print("Size: {d}, {d}, {s}\n", .{ node.size(), node.data().len, node.data() });
            }
        }
        return -1;
    }

    fn get_file_header(self: RomFs, path: []const u8) ?FileHeader {
        std.debug.print("Fetching file header\n", .{});
        const path_without_trailing_separator = std.mem.trimRight(u8, path, "/");
        var it = try std.fs.path.componentIterator(path);
        var component = it.first();
        var node = self.root.first_file_header();
        while (component) |part| : (component = it.next()) {
            std.debug.print("Processing: {s}, {s}\n", .{ part.name, part.path });
            while (!std.mem.eql(u8, node.name(), part.name)) {
                std.debug.print("Node: {s}({d}), part: {s}({d})\n", .{ node.name(), node.name().len, part.name, part.name.len });
                const maybe_node = node.next();
                if (maybe_node == null) {
                    std.debug.print("Return from there\n", .{});
                    return null;
                }
                node = maybe_node.?;
            }

            // if symbolic link then fetch target node
            if (node.filetype() == FileType.SymbolicLink) {
                // iterate through link
                var link_it = try std.fs.path.componentIterator(node.data());
                var link_component = link_it.first();
                while (link_component) |link_part| : (link_component = link_it.next()) {
                    std.debug.print("Part is: {s}\n", .{link_part.name});
                }
            }

            // if last component then return
            if (path_without_trailing_separator.len == part.path.len) {
                std.debug.print("Returning: {s}\n", .{node.name()});
                return node;
            }

            if (node.filetype() == FileType.Directory) {
                std.debug.print("This is directory: {s}\n", .{node.name()});
                node = FileHeader.init(node.memory, node.specinfo());
            } else if (node.filetype() == FileType.SymbolicLink) {
                std.debug.print("symbolic link: size of node: {d}\n", .{node.data().len});
                // node = FileHeader.init(node.memory, node.data());
            }
        }
        return node;
    }

    fn get(ctx: *anyopaque, path: []const u8) ?IFile {
        const self: *RomFs = @ptrCast(@alignCast(ctx));
        const maybe_node = self.get_file_header(path);
        const file = self.allocator.create(RomFsFile) catch return null;
        if (maybe_node) |node| {
            file.* = RomFsFile.init(node);
            file.allocator = self.allocator;
            return file.ifile();
        }
        return null;
    }

    fn has_path(ctx: *anyopaque, path: []const u8) bool {
        const self: *RomFs = @ptrCast(@alignCast(ctx));
        const file = self.get_file_header(path);
        return file != null;
    }
};

const ExpectationList = std.ArrayList([]const u8);
var expected_directories: ExpectationList = undefined;
var did_error: anyerror!void = {};

fn traverse_dir(file: *IFile) void {
    did_error catch return;
    did_error = std.testing.expect(expected_directories.items.len != 0);
    did_error catch {
        std.debug.print("Expectation not found for: '{s}'\n", .{file.name()});
        return;
    };
    const expectation = expected_directories.items[0];
    did_error = std.testing.expectEqualStrings(expectation, file.name());
    did_error catch {
        std.debug.print("Expectation not matched, expected: '{s}', found: '{s}'\n", .{ expectation, file.name() });
        return;
    };
    _ = expected_directories.orderedRemove(0);
}

test "Parsing filesystem" {
    const test_data = @embedFile("test.romfs");
    expected_directories = std.ArrayList([]const u8).init(std.testing.allocator);
    defer expected_directories.deinit();
    var maybe_fs = RomFs.init(std.testing.allocator, test_data);
    if (maybe_fs) |*fs| {
        const ifs = fs.ifilesystem();

        try std.testing.expectEqual(ifs.name(), "romfs");
        const maybe_root_directory = ifs.get("/");
        try std.testing.expect(maybe_root_directory != null);
        if (maybe_root_directory) |root_directory| {
            defer _ = root_directory.close();
            try std.testing.expectEqualStrings(root_directory.name(), ".");
        }
        _ = try expected_directories.appendSlice(&.{ ".", "..", "dev", "subdir", "file.txt" });
        try std.testing.expectEqual(0, ifs.traverse(".", &traverse_dir));
        try did_error;

        _ = try expected_directories.appendSlice(&.{ ".", "test.socket", "pipe1", "fc1", "..", "fb1" });
        try std.testing.expectEqual(0, ifs.traverse("/dev", &traverse_dir));

        _ = try expected_directories.appendSlice(&.{ ".", "f1.txt", "other_dir", "f2.txt", "dir", ".." });
        try std.testing.expectEqual(0, ifs.traverse("/subdir", &traverse_dir));

        _ = try expected_directories.appendSlice(&.{ ".", "f1.txt", "test.txt", ".." });
        try std.testing.expectEqual(0, ifs.traverse("/subdir/dir", &traverse_dir));

        _ = try expected_directories.appendSlice(&.{ ".", "dir", "..", "a.txt", "b.txt" });
        try std.testing.expectEqual(0, ifs.traverse("/subdir/other_dir", &traverse_dir));

        std.debug.print("-=-=-=-=-=-=-=-=-=-=-=-=\n", .{});
        _ = try expected_directories.appendSlice(&.{ ".", "f1.txt", "test.txt", ".." });
        try std.testing.expectEqual(0, ifs.traverse("/subdir/other_dir/dir", &traverse_dir));

        try did_error;
    }
}
