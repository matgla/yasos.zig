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

const kernel = @import("kernel");

const ReadOnlyFileSystem = kernel.fs.ReadOnlyFileSystem;
const IFile = kernel.fs.IFile;
const IDirectoryIterator = kernel.fs.IDirectoryIterator;
const FileType = kernel.fs.FileType;

const RomFsFile = @import("romfs_file.zig").RomFsFile;

const FileSystemHeader = @import("file_system_header.zig").FileSystemHeader;
const FileHeader = @import("file_header.zig").FileHeader;
const RomFsDirectoryIterator = @import("romfs_directory_iterator.zig").RomFsDirectoryIterator;

const interface = @import("interface");

const c = @import("libc_imports").c;

const std = @import("std");

const log = kernel.log;

pub const RomFs = interface.DeriveFromBase(ReadOnlyFileSystem, struct {
    const Self = @This();

    base: ReadOnlyFileSystem,
    root: FileSystemHeader,
    allocator: std.mem.Allocator,
    device_file: IFile,

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "romfs";
    }

    pub fn traverse(self: *Self, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, context: *anyopaque) i32 {
        var maybe_node = self.get_file_header(path);
        if (maybe_node) |*node| {
            if (node.filetype() == FileType.Directory) {
                var it: ?FileHeader = self.create_file_header(node.specinfo());
                while (it) |*child| : (it = child.next()) {
                    var file: RomFsFile = RomFsFile.InstanceType.create(self.allocator, child.*);
                    var ifile = file.interface.new(self.allocator) catch return -1;
                    defer ifile.interface.delete();
                    if (!callback(&ifile, context)) {
                        return 0;
                    }
                }
                return 0;
            }
        }
        return -1;
    }

    pub fn delete(self: *Self) void {
        self.device_file.interface.delete();
    }

    // RomFs interface
    pub fn init(allocator: std.mem.Allocator, device_file: IFile, start_offset: c.off_t) error{NotRomFsFileSystem}!RomFs {
        const fs = FileSystemHeader.init(allocator, device_file, start_offset);
        if (fs) |root| {
            return RomFs.init(.{
                .base = ReadOnlyFileSystem.init(.{}),
                .root = root,
                .allocator = allocator,
                .device_file = device_file,
            });
        }
        return error.NotRomFsFileSystem;
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?IFile {
        const maybe_node = self.get_file_header(path);
        if (maybe_node) |node| {
            return RomFsFile.InstanceType.create(allocator, node).interface.new(allocator) catch return null;
        }
        return null;
    }

    pub fn has_path(self: *Self, path: []const u8) bool {
        const file = self.get_file_header(path);
        return file != null;
    }

    pub fn iterator(self: *Self, path: []const u8) ?IDirectoryIterator {
        var maybe_node = self.get_file_header(path);
        if (maybe_node) |*node| {
            if (node.filetype() == FileType.Directory) {
                const maybe_child: ?FileHeader = self.create_file_header(node.specinfo());
                if (maybe_child) |child| {
                    return RomFsDirectoryIterator.InstanceType.create(child, self.allocator).interface.new(self.allocator) catch {
                        return null;
                    };
                }
            }
        }
        return null;
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self;
        // RomFS is read-only, so formatting is not applicable
        return error.NotSupported;
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat) i32 {
        var maybe_node = self.get_file_header(path);
        if (maybe_node) |*node| {
            node.stat(data);
            return 0;
        }
        return -1;
    }

    fn get_file_header(self: *Self, path: []const u8) ?FileHeader {
        const path_without_trailing_separator = std.mem.trimRight(u8, path, "/");
        var it = try std.fs.path.componentIterator(path);
        var component = it.first();
        var maybe_node = self.root.first_file_header();
        if (maybe_node == null) {
            return null;
        }
        if (path_without_trailing_separator.len < 1) {
            return maybe_node;
        }
        while (component) |part| : (component = it.next()) {
            var filename = maybe_node.?.name(self.allocator);
            while (!std.mem.eql(u8, filename.get_name(), part.name)) {
                maybe_node = maybe_node.?.next();
                if (maybe_node == null) {
                    filename.deinit();
                    return null;
                }

                filename.deinit();
                filename = maybe_node.?.name(self.allocator);
            }
            filename.deinit();
            // if symbolic link then fetch target node
            if (maybe_node) |*node| {
                if (node.filetype() == FileType.SymbolicLink) {
                    // iterate through link
                    const maybe_name = node.read_name_at_offset(self.allocator, 0);
                    if (maybe_name) |*link_name| {
                        defer link_name.deinit();
                        const relative = std.fs.path.resolve(self.allocator, &.{ part.path, "..", link_name.get_name() }) catch return null;
                        defer self.allocator.free(relative);
                        maybe_node = self.get_file_header(relative);
                    }
                }
            }

            if (maybe_node) |*node| {
                // if last component then return
                if (path_without_trailing_separator.len == part.path.len) {
                    if (node.filetype() == FileType.HardLink) {
                        // if hard link then get it
                        return self.create_file_header(node.specinfo());
                    }
                    return maybe_node;
                }
            }

            if (maybe_node) |*node| {
                if (node.filetype() == FileType.Directory) {
                    maybe_node = self.create_file_header(node.specinfo());
                }
            }
        }

        if (maybe_node) |*node| {
            if (node.filetype() == FileType.HardLink) {
                // if hard link then get it
                return self.create_file_header(node.specinfo());
            }
        }
        return maybe_node;
    }

    fn create_file_header(self: *Self, offset: u32) FileHeader {
        return self.root.create_file_header_with_offset(@intCast(offset));
    }
});

const ExpectationList = std.ArrayList([]const u8);
var expected_directories: ExpectationList = undefined;
var did_error: anyerror!void = {};

fn traverse_dir(file: *IFile, _: *anyopaque) bool {
    did_error catch return false;
    did_error = std.testing.expect(expected_directories.items.len != 0);
    var filename = file.interface.name(std.testing.allocator);
    defer filename.deinit();

    did_error catch {
        std.debug.print("Expectation not found for: '{s}'\n", .{filename.get_name()});
        return false;
    };
    const expectation = expected_directories.items[0];
    did_error = std.testing.expectEqualStrings(expectation, filename.get_name());
    did_error catch {
        std.debug.print("Expectation not matched, expected: '{s}', found: '{s}'\n", .{ expectation, filename.get_name() });
        return false;
    };
    _ = expected_directories.orderedRemove(0);
    return true;
}

test "Romfs.ShouldParseFilesystem" {
    const RomfsDeviceStub = @import("tests/romfs_device_stub.zig").RomfsDeviceStub;
    var device = RomfsDeviceStub.InstanceType.init(&std.testing.allocator, "source/fs/romfs/tests/test.romfs");
    var idevice = device.interface.create();
    try idevice.interface.load();
    var device_file = idevice.interface.ifile(std.testing.allocator);
    try std.testing.expect(device_file != null);
    defer device_file.?.interface.delete();
    expected_directories = std.ArrayList([]const u8).init(std.testing.allocator);
    defer expected_directories.deinit();
    var romfs = try RomFs.InstanceType.init(std.testing.allocator, device_file.?.share(), 0);
    var ifs = romfs.interface.create();
    defer ifs.interface.delete();
    const fs_name = ifs.interface.name();
    try std.testing.expectEqual(fs_name, "romfs");
    var maybe_root_directory = ifs.interface.get("/", std.testing.allocator);
    try std.testing.expect(maybe_root_directory != null);
    if (maybe_root_directory) |*root_directory| {
        defer _ = root_directory.interface.delete();
        var name = root_directory.interface.name(std.testing.allocator);
        defer name.deinit();
        try std.testing.expectEqualStrings(name.get_name(), ".");
    }
    _ = try expected_directories.appendSlice(&.{ ".", "..", "dev", "subdir", "file.txt" });
    try std.testing.expectEqual(0, ifs.interface.traverse(".", &traverse_dir, undefined));
    try did_error;

    _ = try expected_directories.appendSlice(&.{ ".", "test.socket", "pipe1", "fc1", "..", "fb1" });
    try std.testing.expectEqual(0, ifs.interface.traverse("/dev", &traverse_dir, undefined));
    try did_error;

    _ = try expected_directories.appendSlice(&.{ ".", "f1.txt", "other_dir", "f2.txt", "dir", ".." });
    try std.testing.expectEqual(0, ifs.interface.traverse("/subdir", &traverse_dir, undefined));
    try did_error;

    _ = try expected_directories.appendSlice(&.{ ".", "f1.txt", "test.txt", ".." });
    try std.testing.expectEqual(0, ifs.interface.traverse("/subdir/dir", &traverse_dir, undefined));
    try did_error;

    _ = try expected_directories.appendSlice(&.{ ".", "dir", "..", "a.txt", "b.txt" });
    try std.testing.expectEqual(0, ifs.interface.traverse("/subdir/other_dir", &traverse_dir, undefined));
    try did_error;

    _ = try expected_directories.appendSlice(&.{ ".", "f1.txt", "test.txt", ".." });
    try std.testing.expectEqual(0, ifs.interface.traverse("/subdir/other_dir/dir", &traverse_dir, undefined));
    try did_error;

    var maybe_file = ifs.interface.get(
        "/file.txt",
        std.testing.allocator,
    );
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        defer _ = file.interface.close();
        defer _ = file.interface.delete();
        try std.testing.expectEqual(34, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.File, file.interface.filetype());
        try std.testing.expectEqualStrings("THis is testing file\nwith content\n", buffer);
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/subdir/f1.txt", std.testing.allocator);
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        defer _ = file.interface.close();
        defer _ = file.interface.delete();
        try std.testing.expectEqual(10, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.File, file.interface.filetype());
        try std.testing.expectEqualStrings("1 2 3 4 5\n", buffer);
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/subdir/f2.txt", std.testing.allocator);
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        defer _ = file.interface.delete();

        try std.testing.expectEqual(9, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.File, file.interface.filetype());
        try std.testing.expectEqualStrings("1\n2\n3\n4\n\n", buffer);
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/subdir/other_dir/a.txt", std.testing.allocator);
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        defer _ = file.interface.delete();
        try std.testing.expectEqual(7, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.File, file.interface.filetype());
        try std.testing.expectEqualStrings("abcdef\n", buffer);
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/subdir/other_dir/b.txt", std.testing.allocator);
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        defer _ = file.interface.delete();
        try std.testing.expectEqual(10, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.File, file.interface.filetype());
        try std.testing.expectEqualStrings("avadad\nww\n", buffer);
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/subdir/dir/test.txt", std.testing.allocator);
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        const f = &file.interface;
        defer _ = f.delete();
        try std.testing.expectEqual(36, f.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(f.size()));
        try std.testing.expectEqual(f.size(), f.read(buffer));
        try std.testing.expectEqual(FileType.File, f.filetype());
        try std.testing.expectEqualStrings("This is test file\nWith some content\n", buffer);
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/subdir/dir/f1.txt", std.testing.allocator);
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        defer _ = file.interface.delete();
        try std.testing.expectEqual(10, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.File, file.interface.filetype());
        try std.testing.expectEqualStrings("1 2 3 4 5\n", buffer);
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/subdir/other_dir/dir/test.txt", std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        defer _ = file.interface.delete();
        try std.testing.expectEqual(36, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.File, file.interface.filetype());
        try std.testing.expectEqualStrings("This is test file\nWith some content\n", buffer);
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/dev/test.socket", std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        defer _ = file.interface.delete();
        try std.testing.expectEqual(0, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.Socket, file.interface.filetype());
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/dev/pipe1", std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        defer _ = file.interface.delete();
        try std.testing.expectEqual(0, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.Fifo, file.interface.filetype());
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/dev/fc1", std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        defer _ = file.interface.delete();
        try std.testing.expectEqual(0, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.CharDevice, file.interface.filetype());
        std.testing.allocator.free(buffer);
    }

    maybe_file = ifs.interface.get("/dev/fb1", std.testing.allocator);
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |*file| {
        defer _ = file.interface.delete();
        try std.testing.expectEqual(0, file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, @intCast(file.interface.size()));
        try std.testing.expectEqual(file.interface.size(), file.interface.read(buffer));
        try std.testing.expectEqual(FileType.BlockDevice, file.interface.filetype());
        std.testing.allocator.free(buffer);
    }
}
