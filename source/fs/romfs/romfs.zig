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
        const maybe_fs_size = FileSystemHeader.get_romfs_size(memory);
        if (maybe_fs_size == null) {
            return null;
        }
        const fs = FileSystemHeader.init(@as([]const u8, memory.ptr[0..@intCast(maybe_fs_size.?)]));
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

    fn create(_: *anyopaque, _: []const u8, _: i32) ?IFile {
        // read-only filesystem
        return null;
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

    fn traverse(ctx: *anyopaque, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, context: *anyopaque) i32 {
        const self: *RomFs = @ptrCast(@alignCast(ctx));
        const maybe_node = self.get_file_header(path);
        if (maybe_node) |node| {
            if (node.filetype() == FileType.Directory) {
                var it: ?FileHeader = FileHeader.init(node.memory, node.specinfo());
                while (it) |child| : (it = child.next()) {
                    var file: RomFsFile = RomFsFile.create(child, self.allocator);
                    var ifile = file.ifile();
                    if (!callback(&ifile, context)) {
                        return 0;
                    }
                }
                return 0;
            }
        }
        return -1;
    }

    fn get_file_header(self: RomFs, path: []const u8) ?FileHeader {
        const path_without_trailing_separator = std.mem.trimRight(u8, path, "/");
        var it = try std.fs.path.componentIterator(path);
        var component = it.first();
        var maybe_node = self.root.first_file_header();
        if (maybe_node == null) {
            return null;
        }
        while (component) |part| : (component = it.next()) {
            while (!std.mem.eql(u8, maybe_node.?.name(), part.name)) {
                maybe_node = maybe_node.?.next();
                if (maybe_node == null) {
                    return null;
                }
            }

            // if symbolic link then fetch target node
            if (maybe_node) |node| {
                if (node.filetype() == FileType.SymbolicLink) {
                    // iterate through link
                    const relative = std.fs.path.resolve(self.allocator, &.{ part.path, "..", node.data() }) catch return null;
                    defer self.allocator.free(relative);
                    maybe_node = self.get_file_header(relative);
                }
            }

            if (maybe_node) |node| {
                // if last component then return
                if (path_without_trailing_separator.len == part.path.len) {
                    if (node.filetype() == FileType.HardLink) {
                        // if hard link then get it
                        return FileHeader.init(node.memory, node.specinfo());
                    }
                    return maybe_node;
                }
            }

            if (maybe_node) |node| {
                if (node.filetype() == FileType.Directory) {
                    maybe_node = FileHeader.init(node.memory, node.specinfo());
                }
            }
        }

        if (maybe_node) |node| {
            if (node.filetype() == FileType.HardLink) {
                // if hard link then get it
                return FileHeader.init(node.memory, node.specinfo());
            }
        }
        return maybe_node;
    }

    fn get(ctx: *anyopaque, path: []const u8) ?IFile {
        const self: *RomFs = @ptrCast(@alignCast(ctx));
        const maybe_node = self.get_file_header(path);
        if (maybe_node) |node| {
            const file = self.allocator.create(RomFsFile) catch return null;
            file.* = RomFsFile.create(node, self.allocator);
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

fn traverse_dir(file: *IFile, _: *anyopaque) bool {
    did_error catch return false;
    did_error = std.testing.expect(expected_directories.items.len != 0);
    did_error catch {
        std.debug.print("Expectation not found for: '{s}'\n", .{file.name()});
        return false;
    };
    const expectation = expected_directories.items[0];
    did_error = std.testing.expectEqualStrings(expectation, file.name());
    did_error catch {
        std.debug.print("Expectation not matched, expected: '{s}', found: '{s}'\n", .{ expectation, file.name() });
        return false;
    };
    _ = expected_directories.orderedRemove(0);
    return true;
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
        try std.testing.expectEqual(0, ifs.traverse(".", &traverse_dir, undefined));
        try did_error;

        _ = try expected_directories.appendSlice(&.{ ".", "test.socket", "pipe1", "fc1", "..", "fb1" });
        try std.testing.expectEqual(0, ifs.traverse("/dev", &traverse_dir, undefined));
        try did_error;

        _ = try expected_directories.appendSlice(&.{ ".", "f1.txt", "other_dir", "f2.txt", "dir", ".." });
        try std.testing.expectEqual(0, ifs.traverse("/subdir", &traverse_dir, undefined));
        try did_error;

        _ = try expected_directories.appendSlice(&.{ ".", "f1.txt", "test.txt", ".." });
        try std.testing.expectEqual(0, ifs.traverse("/subdir/dir", &traverse_dir, undefined));
        try did_error;

        _ = try expected_directories.appendSlice(&.{ ".", "dir", "..", "a.txt", "b.txt" });
        try std.testing.expectEqual(0, ifs.traverse("/subdir/other_dir", &traverse_dir, undefined));
        try did_error;

        _ = try expected_directories.appendSlice(&.{ ".", "f1.txt", "test.txt", ".." });
        try std.testing.expectEqual(0, ifs.traverse("/subdir/other_dir/dir", &traverse_dir, undefined));
        try did_error;

        var maybe_file = ifs.get("/file.txt");
        try std.testing.expect(maybe_file != null);
        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(34, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.File, file.filetype());
            try std.testing.expectEqualStrings("THis is testing file\nwith content\n", buffer);
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/subdir/f1.txt");
        try std.testing.expect(maybe_file != null);

        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(10, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.File, file.filetype());
            try std.testing.expectEqualStrings("1 2 3 4 5\n", buffer);
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/subdir/f2.txt");
        try std.testing.expect(maybe_file != null);

        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(9, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.File, file.filetype());
            try std.testing.expectEqualStrings("1\n2\n3\n4\n\n", buffer);
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/subdir/other_dir/a.txt");
        try std.testing.expect(maybe_file != null);

        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(7, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.File, file.filetype());
            try std.testing.expectEqualStrings("abcdef\n", buffer);
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/subdir/other_dir/b.txt");
        try std.testing.expect(maybe_file != null);

        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(10, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.File, file.filetype());
            try std.testing.expectEqualStrings("avadad\nww\n", buffer);
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/subdir/dir/test.txt");
        try std.testing.expect(maybe_file != null);

        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(36, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.File, file.filetype());
            try std.testing.expectEqualStrings("This is test file\nWith some content\n", buffer);
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/subdir/dir/f1.txt");
        try std.testing.expect(maybe_file != null);

        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(10, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.File, file.filetype());
            try std.testing.expectEqualStrings("1 2 3 4 5\n", buffer);
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/subdir/other_dir/dir/test.txt");
        try std.testing.expect(maybe_file != null);
        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(36, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.File, file.filetype());
            try std.testing.expectEqualStrings("This is test file\nWith some content\n", buffer);
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/dev/test.socket");
        try std.testing.expect(maybe_file != null);
        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(0, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.Socket, file.filetype());
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/dev/pipe1");
        try std.testing.expect(maybe_file != null);
        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(0, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.Fifo, file.filetype());
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/dev/fc1");
        try std.testing.expect(maybe_file != null);
        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(0, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.CharDevice, file.filetype());
            std.testing.allocator.free(buffer);
        }

        maybe_file = ifs.get("/dev/fb1");
        try std.testing.expect(maybe_file != null);
        if (maybe_file) |file| {
            defer _ = file.close();
            try std.testing.expectEqual(0, file.size());
            const buffer = try std.testing.allocator.alloc(u8, @intCast(file.size()));
            try std.testing.expectEqual(file.size(), file.read(buffer));
            try std.testing.expectEqual(FileType.BlockDevice, file.filetype());
            std.testing.allocator.free(buffer);
        }
    }
}
