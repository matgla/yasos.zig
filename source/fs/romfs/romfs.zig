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
const RomFsDirectory = @import("romfs_directory.zig").RomFsDirectory;

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

    pub fn delete(self: *Self) void {
        self.device_file.interface.delete();
    }

    // RomFs interface
    pub fn init(allocator: std.mem.Allocator, device_file: IFile, start_offset: c.off_t) !RomFs {
        const fs = try FileSystemHeader.init(allocator, device_file, start_offset);
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

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        var header = try self.get_file_header(path);
        defer header.deinit();
        if (header.filetype() != FileType.Directory) {
            return try RomFsFile.InstanceType.create_node(self.allocator, try header.dupe());
        } else {
            return try RomFsDirectory.InstanceType.create_node(self.allocator, try header.dupe(), &self.root);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self;
        // RomFS is read-only, so formatting is not applicable
        return error.NotSupported;
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat) anyerror!void {
        var node = try self.get_file_header(path);
        defer node.deinit();
        node.stat(data);
    }

    fn get_file_header(self: *Self, path: []const u8) !FileHeader {
        const path_without_trailing_separator = std.mem.trimRight(u8, path, "/");
        var it = try std.fs.path.componentIterator(path);
        var component = it.first();
        var maybe_node: ?FileHeader = try self.root.first_file_header();
        if (path_without_trailing_separator.len < 1) {
            return maybe_node orelse kernel.errno.ErrnoSet.InvalidArgument;
        }
        while (component) |part| : (component = it.next()) {
            if (maybe_node == null) {
                return kernel.errno.ErrnoSet.NoEntry;
            }
            var filename = maybe_node.?.name();
            while (!std.mem.eql(u8, filename, part.name)) {
                errdefer maybe_node.?.deinit();
                const next = try maybe_node.?.next();
                maybe_node.?.deinit();
                maybe_node = next;
                if (maybe_node == null) {
                    return kernel.errno.ErrnoSet.NoEntry;
                }
                filename = maybe_node.?.name();
            }
            // if symbolic link then fetch target node
            if (maybe_node) |*node| {
                if (node.filetype() == FileType.SymbolicLink) {
                    // iterate through link
                    const maybe_name = node.read_name_at_offset(self.allocator, 0);
                    if (maybe_name) |*link_name| {
                        defer link_name.deinit();
                        {
                            errdefer maybe_node.?.deinit();
                            maybe_node.?.deinit();
                            maybe_node = null;
                        }
                        const relative = try std.fs.path.resolve(self.allocator, &.{ part.path, "..", link_name.get_name() });
                        defer self.allocator.free(relative);

                        maybe_node = try self.get_file_header(relative);
                    }
                }
            }

            if (maybe_node) |*node| {
                // if last component then return
                if (path_without_trailing_separator.len == part.path.len) {
                    if (node.filetype() == FileType.HardLink) {
                        // if hard link then get it
                        const specinfo = node.specinfo();
                        node.deinit();
                        maybe_node = null;
                        return self.create_file_header(specinfo);
                    }
                    return maybe_node orelse kernel.errno.ErrnoSet.NoEntry;
                }
            }

            if (maybe_node) |*node| {
                if (node.filetype() == FileType.Directory) {
                    const specinfo = node.specinfo();
                    node.deinit();
                    maybe_node = try self.create_file_header(specinfo);
                }
            }
        }

        if (maybe_node) |*node| {
            if (node.filetype() == FileType.HardLink) {
                // if hard link then get it
                const specinfo = node.specinfo();
                node.deinit();
                return self.create_file_header(specinfo);
            }
        }
        return maybe_node orelse kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        _ = flags;
        var node = try self.get(path);
        defer node.delete();

        if ((mode & c.X_OK) != 0) {
            if (node.filetype() == FileType.Directory) {
                return kernel.errno.ErrnoSet.IsADirectory;
            }
        }

        if ((mode & c.W_OK) != 0) {
            return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
        }
    }

    pub fn create_file_header(self: *Self, offset: u32) !FileHeader {
        return try self.root.create_file_header_with_offset(@intCast(offset));
    }
});

fn test_file(fs: kernel.fs.IFileSystem, path: []const u8, size: c_ulong, content: []const u8, filetype: kernel.fs.FileType) !void {
    var ifs = fs;
    var maybe_node = ifs.interface.get(
        path,
        std.testing.allocator,
    );
    errdefer if (maybe_node) |*n| n.delete();
    if (maybe_node) |*node| {
        try std.testing.expectEqual(filetype, node.filetype());
        var file = node.as_file().?;
        defer _ = file.interface.close();
        defer _ = file.interface.delete();
        var stat: c.struct_stat = undefined;
        file.interface.stat(&stat);
        try std.testing.expectEqual(size, stat.st_size);
        const buffer = try std.testing.allocator.alloc(u8, stat.st_size);
        try std.testing.expectEqual(@as(isize, @intCast(stat.st_size)), file.interface.read(buffer));
        try std.testing.expectEqual(filetype, file.interface.filetype());
        try std.testing.expectEqualStrings(content, buffer);
        std.testing.allocator.free(buffer);
    }
}

test "Romfs.ShouldParseFilesystem" {
    const RomfsDeviceStub = @import("tests/romfs_device_stub.zig").RomfsDeviceStub;
    const verify_directory_content = @import("../tests/directory_traverser.zig").verify_directory_content;
    var device = try RomfsDeviceStub.InstanceType.init(std.testing.allocator, "source/fs/romfs/tests/test.romfs");
    var idevice = device.interface.create();
    try idevice.interface.load();
    var device_node = try idevice.interface.node();
    var romfs = try RomFs.InstanceType.init(std.testing.allocator, device_node.as_file().?, 0);
    var ifs = romfs.interface.create();
    defer ifs.interface.delete();
    const fs_name = ifs.interface.name();
    try std.testing.expectEqual(fs_name, "romfs");
    var root_directory = try ifs.interface.get("/");
    defer _ = root_directory.delete();
    const name = root_directory.name();
    try std.testing.expectEqualStrings(name, ".");

    try verify_directory_content(&ifs, "/", &.{
        .{ .name = ".", .kind = .Directory },
        .{ .name = "..", .kind = .HardLink },
        .{ .name = "dev", .kind = .Directory },
        .{ .name = "subdir", .kind = .Directory },
        .{ .name = "file.txt", .kind = .File },
    });

    try verify_directory_content(&ifs, "/dev", &.{
        .{ .name = ".", .kind = .HardLink },
        .{ .name = "..", .kind = .HardLink },
        .{ .name = "test.socket", .kind = .Socket },
        .{ .name = "pipe1", .kind = .Fifo },
        .{ .name = "fc1", .kind = .CharDevice },
        .{ .name = "fb1", .kind = .BlockDevice },
    });

    try verify_directory_content(&ifs, "/subdir", &.{
        .{ .name = ".", .kind = .HardLink },
        .{ .name = "..", .kind = .HardLink },
        .{ .name = "f1.txt", .kind = .File },
        .{ .name = "f2.txt", .kind = .File },
        .{ .name = "other_dir", .kind = .Directory },
        .{ .name = "dir", .kind = .Directory },
    });

    try verify_directory_content(&ifs, "/subdir/other_dir", &.{
        .{ .name = ".", .kind = .HardLink },
        .{ .name = "..", .kind = .HardLink },
        .{ .name = "a.txt", .kind = .File },
        .{ .name = "b.txt", .kind = .File },
        .{ .name = "dir", .kind = .SymbolicLink },
    });

    try verify_directory_content(&ifs, "/subdir/dir", &.{
        .{ .name = ".", .kind = .HardLink },
        .{ .name = "..", .kind = .HardLink },
        .{ .name = "test.txt", .kind = .File },
        .{ .name = "f1.txt", .kind = .HardLink },
    });

    try test_file(ifs, "/file.txt", 34, "THis is testing file\nwith content\n", kernel.fs.FileType.File);
    try test_file(ifs, "/subdir/f1.txt", 10, "1 2 3 4 5\n", kernel.fs.FileType.File);
    try test_file(ifs, "/subdir/f2.txt", 9, "1\n2\n3\n4\n\n", kernel.fs.FileType.File);
    try test_file(ifs, "/subdir/other_dir/a.txt", 7, "abcdef\n", kernel.fs.FileType.File);
    try test_file(ifs, "/subdir/other_dir/b.txt", 10, "avadad\nww\n", kernel.fs.FileType.File);
    try test_file(ifs, "/subdir/dir/test.txt", 36, "This is test file\nWith some content\n", kernel.fs.FileType.File);
    try test_file(ifs, "/subdir/dir/f1.txt", 10, "1 2 3 4 5\n", kernel.fs.FileType.File);
    try test_file(ifs, "/subdir/other_dir/dir/test.txt", 36, "This is test file\nWith some content\n", kernel.fs.FileType.File);
    try test_file(ifs, "/dev/test.socket", 0, "", kernel.fs.FileType.Socket);
    try test_file(ifs, "/dev/pipe1", 0, "", kernel.fs.FileType.Fifo);
    try test_file(ifs, "/dev/fc1", 0, "", kernel.fs.FileType.CharDevice);
    try test_file(ifs, "/dev/fb1", 0, "", kernel.fs.FileType.BlockDevice);
}

test "RomFs.ShouldGetFilesFromDirectory" {
    const RomfsDeviceStub = @import("tests/romfs_device_stub.zig").RomfsDeviceStub;
    var device = try RomfsDeviceStub.InstanceType.init(std.testing.allocator, "source/fs/romfs/tests/test.romfs");
    var idevice = device.interface.create();
    try idevice.interface.load();
    var device_node = try idevice.interface.node();
    var romfs = try RomFs.InstanceType.init(std.testing.allocator, device_node.as_file().?, 0);
    var ifs = romfs.interface.create();
    defer ifs.interface.delete();
    const fs_name = ifs.interface.name();
    try std.testing.expectEqual(fs_name, "romfs");
    var dev_node = try ifs.interface.get("/dev");
    defer dev_node.delete();
    var maybe_dev_directory = dev_node.as_directory();
    try std.testing.expect(maybe_dev_directory != null);
    if (maybe_dev_directory) |*dir| {
        const name = dir.interface.name();
        try std.testing.expectEqualStrings("dev", name);
        var it = try dir.interface.iterator();
        defer it.interface.delete();
        while (it.interface.next()) |entry| {
            var node: kernel.fs.Node = undefined;
            try dir.interface.get(entry.name, &node);
            defer node.delete();
        }
    }
}
