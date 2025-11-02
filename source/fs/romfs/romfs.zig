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
        return RomFs.init(.{
            .base = ReadOnlyFileSystem.init(.{}),
            .root = fs,
            .allocator = allocator,
            .device_file = device_file,
        });
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        var header = try self.get_file_header(path, true);
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

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_symlinks: bool) anyerror!void {
        var node = try self.get_file_header(path, follow_symlinks);
        defer node.deinit();
        node.stat(data);
    }

    fn get_file_header(self: *Self, path: []const u8, resolve_link: bool) !FileHeader {
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
                errdefer if (maybe_node) |*n| n.deinit();
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
                    if (!resolve_link) {
                        return maybe_node orelse kernel.errno.ErrnoSet.NoEntry;
                    }
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

                        maybe_node = try self.get_file_header(relative, resolve_link);
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
    var node = try ifs.interface.get(path);
    errdefer node.delete();
    try std.testing.expectEqual(filetype, node.filetype());
    var file = node.as_file().?;
    defer _ = file.interface.delete();
    const fsize = file.interface.size();
    try std.testing.expectEqual(size, fsize);
    const buffer = try std.testing.allocator.alloc(u8, fsize);
    try std.testing.expectEqual(@as(isize, @intCast(fsize)), file.interface.read(buffer));
    try std.testing.expectEqual(filetype, file.interface.filetype());
    try std.testing.expectEqualStrings(content, buffer);
    std.testing.allocator.free(buffer);
}

fn load_test_romfs() !kernel.fs.IFileSystem {
    const RomfsDeviceStubFile = @import("tests/romfs_device_stub.zig").RomfsDeviceStubFile;
    var device = try RomfsDeviceStubFile.InstanceType.create_node(std.testing.allocator, "source/fs/romfs/tests/test.romfs", null);
    var romfs = try RomFs.InstanceType.init(std.testing.allocator, device.as_file().?, 0);
    return try romfs.interface.new(std.testing.allocator);
}

test "Romfs.ShouldParseFilesystem" {
    const verify_directory_content = @import("../tests/directory_traverser.zig").verify_directory_content;
    var ifs = try load_test_romfs();
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
    var ifs = try load_test_romfs();
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

test "RomFs.ShouldStatFile" {
    var ifs = try load_test_romfs();
    defer ifs.interface.delete();

    var stat_buf: c.struct_stat = undefined;
    try ifs.interface.stat("/file.txt", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFREG), stat_buf.st_mode);
    try std.testing.expectEqual(34, stat_buf.st_size);
}

test "RomFs.ShouldStatDirectory" {
    var ifs = try load_test_romfs();
    defer ifs.interface.delete();

    var stat_buf: c.struct_stat = undefined;
    try ifs.interface.stat("/subdir", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
}

test "RomFs.ShouldStatRootDirectory" {
    var ifs = try load_test_romfs();
    defer ifs.interface.delete();

    var stat_buf: c.struct_stat = undefined;
    try ifs.interface.stat("/", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
}

test "RomFs.ShouldStatNestedFile" {
    var ifs = try load_test_romfs();
    defer ifs.interface.delete();

    var stat_buf: c.struct_stat = undefined;
    try ifs.interface.stat("/subdir/dir/test.txt", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFREG), stat_buf.st_mode);
    try std.testing.expectEqual(36, stat_buf.st_size);
}

test "RomFs.ShouldStatSpecialFiles" {
    var ifs = try load_test_romfs();
    defer ifs.interface.delete();

    var stat_buf: c.struct_stat = undefined;

    // Socket
    try ifs.interface.stat("/dev/test.socket", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFSOCK), stat_buf.st_mode);

    // FIFO
    try ifs.interface.stat("/dev/pipe1", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFIFO), stat_buf.st_mode);

    // Character device
    try ifs.interface.stat("/dev/fc1", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFCHR), stat_buf.st_mode);

    // Block device
    try ifs.interface.stat("/dev/fb1", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFBLK), stat_buf.st_mode);

    // Symlink
    try ifs.interface.stat("/subdir/other_dir/dir", &stat_buf, false);
    try std.testing.expectEqual(@as(c_uint, c.S_IFLNK), stat_buf.st_mode);

    try ifs.interface.stat("/subdir/other_dir/dir", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
}

test "RomFs.ShouldRejectFormat" {
    var ifs = try load_test_romfs();
    defer ifs.interface.delete();

    try std.testing.expectError(error.NotSupported, ifs.interface.format());
}

test "RomFs.ShouldSeekAndTellInFile" {
    var ifs = try load_test_romfs();
    defer ifs.interface.delete();

    var node = try ifs.interface.get("/file.txt");
    defer node.delete();

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        defer _ = file.interface.delete();

        // Get file size first
        const file_size = file.interface.size();

        // Test initial position (should be 0)
        var pos = file.interface.tell();
        try std.testing.expectEqual(@as(c.off_t, 0), pos);

        // Test SEEK_SET - seek to position 5
        pos = try file.interface.seek(5, c.SEEK_SET);
        try std.testing.expectEqual(@as(c.off_t, 5), pos);
        try std.testing.expectEqual(@as(c.off_t, 5), file.interface.tell());

        // Test SEEK_CUR - seek forward 10 bytes from current position (5)
        pos = try file.interface.seek(10, c.SEEK_CUR);
        try std.testing.expectEqual(@as(c.off_t, 15), pos);
        try std.testing.expectEqual(@as(c.off_t, 15), file.interface.tell());

        // Test SEEK_CUR - seek backward 5 bytes from current position (15)
        pos = try file.interface.seek(-5, c.SEEK_CUR);
        try std.testing.expectEqual(@as(c.off_t, 10), pos);
        try std.testing.expectEqual(@as(c.off_t, 10), file.interface.tell());

        // Test SEEK_END - seek to end of file
        pos = try file.interface.seek(0, c.SEEK_END);
        try std.testing.expectEqual(@as(c.off_t, @intCast(file_size)), pos);
        try std.testing.expectEqual(@as(c.off_t, @intCast(file_size)), file.interface.tell());

        // Test SEEK_END - seek 10 bytes before end
        pos = try file.interface.seek(-10, c.SEEK_END);
        try std.testing.expectEqual(@as(c.off_t, @intCast(file_size - 10)), pos);
        try std.testing.expectEqual(@as(c.off_t, @intCast(file_size - 10)), file.interface.tell());

        // Test SEEK_SET - seek back to beginning
        pos = try file.interface.seek(0, c.SEEK_SET);
        try std.testing.expectEqual(@as(c.off_t, 0), pos);
        try std.testing.expectEqual(@as(c.off_t, 0), file.interface.tell());

        // Verify read updates position correctly
        var buffer: [5]u8 = undefined;
        const bytes_read = file.interface.read(&buffer);
        try std.testing.expectEqual(@as(isize, 5), bytes_read);
        try std.testing.expectEqual(@as(c.off_t, 5), file.interface.tell());

        // Test SEEK_CUR with 0 offset (should return current position without moving)
        pos = try file.interface.seek(0, c.SEEK_CUR);
        try std.testing.expectEqual(@as(c.off_t, 5), pos);
        try std.testing.expectEqual(@as(c.off_t, 5), file.interface.tell());

        // Test invalid seek (negative position with SEEK_SET)
        try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.interface.seek(-1, c.SEEK_SET));
        try std.testing.expectEqual(@as(c.off_t, 5), file.interface.tell());

        // Test invalid seek (beyond end of file with SEEK_SET)
        try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.interface.seek(@as(c.off_t, @intCast(file_size)) + 1, c.SEEK_SET));
        try std.testing.expectEqual(@as(c.off_t, 5), file.interface.tell());

        // Test invalid seek whence
        try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.interface.seek(10, -123));
        try std.testing.expectEqual(@as(c.off_t, 5), file.interface.tell());
    }
}

test "RomFs.ShouldReportMemoryMappedFiles" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    var node = try fs.interface.get("/subdir/dir/test.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        try std.testing.expectEqualStrings("test.txt", file.interface.name());
        var status: kernel.fs.FileMemoryMapAttributes = undefined;
        try std.testing.expectEqual(-1, file.interface.ioctl(-1, &status));
        try std.testing.expectEqual(0, file.interface.ioctl(@intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus), &status));
        try std.testing.expectEqual(true, status.is_memory_mapped);
    }
}

test "RomFs.DoesNothingForFcntl" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    var node = try fs.interface.get("/subdir/dir/test.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        var data: i32 = 0;
        try std.testing.expectEqual(0, file.interface.fcntl(-1, &data));
        try std.testing.expectEqual(0, data);
        try std.testing.expectEqual(0, file.interface.fcntl(-123, null));
    }
}

test "RomFs.ShouldMountAndUnmount" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    const mount_result = fs.interface.mount();
    try std.testing.expectEqual(@as(i32, 0), mount_result);

    const umount_result = fs.interface.umount();
    try std.testing.expectEqual(@as(i32, 0), umount_result);
}

test "RomFs.ShouldRejectCreate" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    try std.testing.expectError(kernel.errno.ErrnoSet.ReadOnlyFileSystem, fs.interface.create("/newfile.txt", 0o644));
}

test "RomFs.ShouldRejectMkdir" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    try std.testing.expectError(kernel.errno.ErrnoSet.ReadOnlyFileSystem, fs.interface.mkdir("/newdir", 0o755));
}

test "RomFs.ShouldRejectLink" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    try std.testing.expectError(kernel.errno.ErrnoSet.ReadOnlyFileSystem, fs.interface.link("/file.txt", "/link.txt"));
}

test "RomFs.ShouldRejectUnlink" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    try std.testing.expectError(kernel.errno.ErrnoSet.ReadOnlyFileSystem, fs.interface.unlink("/file.txt"));
}

test "RomFs.ShouldAccessFile" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    // Test read access on file
    try fs.interface.access("/file.txt", c.R_OK, 0);

    // Test file existence
    try fs.interface.access("/file.txt", c.F_OK, 0);

    // Test write access should fail (read-only filesystem)
    try std.testing.expectError(kernel.errno.ErrnoSet.ReadOnlyFileSystem, fs.interface.access("/file.txt", c.W_OK, 0));
}

test "RomFs.ShouldAccessDirectory" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    // Test directory existence
    try fs.interface.access("/subdir", c.F_OK, 0);

    // Test execute access on directory should fail with IsADirectory
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, fs.interface.access("/subdir", c.X_OK, 0));
}

test "RomFs.ShouldRejectAccessOnNonExistentPath" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, fs.interface.access("/nonexistent.txt", c.F_OK, 0));
}

test "RomFs.ShouldRejectGettingNonExistentPathFromDirectory" {
    var fs = try load_test_romfs();
    defer fs.interface.delete();

    var dir = try fs.interface.get("/subdir");
    defer dir.delete();
    var maybe_directory = dir.as_directory();
    try std.testing.expect(maybe_directory != null);
    if (maybe_directory) |*d| {
        var node: kernel.fs.Node = undefined;
        try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, d.interface.get("nonexistent.txt", &node));
        try d.interface.get("dir", &node);
        defer node.delete();
        try std.testing.expectEqualStrings("dir", node.name());
    }
}

test "RomFs.ShouldReportMappedMemory" {
    const RomfsDeviceStubFile = @import("tests/romfs_device_stub.zig").RomfsDeviceStubFile;
    var device = try RomfsDeviceStubFile.InstanceType.create_node(std.testing.allocator, "source/fs/romfs/tests/test.romfs", 0xfeedface);
    var romfs = try RomFs.InstanceType.init(std.testing.allocator, device.as_file().?, 0);
    var sut = try romfs.interface.new(std.testing.allocator);
    defer sut.interface.delete();

    var node = try sut.interface.get("/subdir/dir/test.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        try std.testing.expectEqualStrings("test.txt", file.interface.name());
        var status: kernel.fs.FileMemoryMapAttributes = undefined;
        try std.testing.expectEqual(0, file.interface.ioctl(@intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus), &status));
        try std.testing.expectEqual(true, status.is_memory_mapped);
        try std.testing.expect(status.mapped_address_r != null);
        const file_offset = 0x350;
        if (status.mapped_address_r) |addr| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrFromInt(0xfeedface + file_offset)), addr);
        }

        try std.testing.expectEqual(null, status.mapped_address_w);
    }
}
