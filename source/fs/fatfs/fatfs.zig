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

const std = @import("std");

const oop = @import("interface");
const fatfs = @import("zfat");
const c = @import("libc_imports").c;

const kernel = @import("kernel");

const log = std.log.scoped(.@"fs/fatfs");

const FatFsFile = @import("fatfs_file.zig").FatFsFile;
const FatFsDirectory = @import("fatfs_directory.zig").FatFsDirectory;
const FatFsIterator = @import("fatfs_directory.zig").FatFsIterator;

const fatfs_error_to_errno = @import("errno_converter.zig").fatfs_error_to_errno;

var global_fs: fatfs.FileSystem = undefined;
var workspace_buffer: [4096]u8 = undefined;
pub const FatFs = oop.DeriveFromBase(kernel.fs.IFileSystem, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _device: kernel.fs.IFile,
    _disk_wrapper: DiskWrapper,

    pub fn init(allocator: std.mem.Allocator, device: kernel.fs.IFile) !FatFs {
        var d = device;
        return FatFs.init(.{
            ._allocator = allocator,
            ._device = device,
            ._disk_wrapper = DiskWrapper{
                .device = try d.clone(),
            },
        });
    }

    pub fn mount(self: *Self) i32 {
        log.debug("Mounting FAT filesystem", .{});
        fatfs.disks[0] = &self._disk_wrapper.interface;
        global_fs.mount("0:", true) catch |err| {
            log.err("Failed to mount FAT filesystem: {s}", .{@errorName(err)});
            return -1;
        };
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self.umount();
        self._device.interface.delete();
        self._disk_wrapper.device.interface.delete();
    }

    pub fn umount(self: *Self) i32 {
        log.debug("Unmounting FAT filesystem", .{});
        _ = self;
        fatfs.FileSystem.unmount("0:") catch |err| {
            log.err("Failed to unmount FAT filesystem: {s}", .{@errorName(err)});
            return -1;
        };
        return 0;
    }

    pub fn create(self: *Self, path: []const u8, _: i32) anyerror!void {
        log.info("Creating file at path: {s}", .{path});
        const filepath = try self._allocator.dupeZ(u8, path);
        defer self._allocator.free(filepath);
        var file = try fatfs.File.create(filepath);
        file.close();
    }

    pub fn mkdir(self: *Self, path: []const u8, _: i32) anyerror!void {
        log.info("Creating directory at path: {s}", .{path});
        const filepath = try self._allocator.dupeZ(u8, path);
        defer self._allocator.free(filepath);
        _ = fatfs.mkdir(filepath) catch |err| {
            return fatfs_error_to_errno(err);
        };
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        log.info("Removing file or directory at path: {s}", .{path});
        const filepath = try self._allocator.dupeZ(u8, path);
        defer self._allocator.free(filepath);
        try fatfs.unlink(filepath);
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "fatfs";
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        const filepath = try self._allocator.dupeZ(u8, path);
        defer self._allocator.free(filepath);

        var dir: ?fatfs.Dir = fatfs.Dir.open(filepath) catch blk: {
            break :blk null;
        };

        if (dir) |*d| {
            d.close();
            return try FatFsDirectory.InstanceType.create_node(self._allocator, filepath);
        }
        return try FatFsFile.InstanceType.create_node(self._allocator, filepath);
    }

    pub fn format(self: *Self) anyerror!void {
        log.info("Formatting FAT filesystem", .{});

        fatfs.disks[0] = &self._disk_wrapper.interface;
        fatfs.mkfs(
            "0:",
            .{ .filesystem = .fat32, .sector_align = 1, .use_partitions = false },
            &workspace_buffer,
        ) catch |err| {
            log.err("Failed to format FAT filesystem: {s}", .{@errorName(err)});
            return err;
        };
        _ = self.umount();
        _ = self.mount();
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_symlinks: bool) anyerror!void {
        _ = follow_symlinks;
        if (std.mem.eql(u8, path, "/") or path.len == 0) {
            data.st_blksize = 512;
            data.st_size = 0;
            data.st_mode = c.S_IFDIR;
            data.st_nlink = 0; // Number of links,
            data.st_uid = 0;
            data.st_gid = 0; // Group ID
            data.st_dev = 0; // Device ID
            data.st_ino = 0; // Inode number
            data.st_rdev = 0; // Device type (for special files)
            data.st_blocks = 0;
            return;
        }
        var path_c = try std.fmt.allocPrintSentinel(self._allocator, "0:/{s} ", .{path}, 0);
        path_c[path_c.len - 1] = 0; // Null-terminate
        defer self._allocator.free(path_c);
        const finfo = fatfs.stat(path_c) catch |err| {
            return fatfs_error_to_errno(err);
        };
        data.st_blksize = 512;
        data.st_size = @intCast(finfo.size);
        data.st_mode = if (finfo.kind == .Directory) c.S_IFDIR else c.S_IFREG;
        data.st_nlink = 0; // Number of links,
        data.st_uid = 0;
        data.st_gid = 0; // Group ID
        data.st_dev = 0; // Device ID
        data.st_ino = 0; // Inode number
        data.st_rdev = 0; // Device type (for special files)
        data.st_blocks = @intCast((finfo.size + 511) / 512);
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = old_path;
        _ = new_path;
        return error.NotSupported;
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        _ = flags;
        var node = try self.get(path);
        node.delete();
        if ((mode & c.W_OK) != 0 or (mode & c.X_OK) != 0) {
            if (node.filetype() == kernel.fs.FileType.Directory) {
                return kernel.errno.ErrnoSet.IsADirectory;
            }
        }
    }

    const DiskWrapper = struct {
        const sector_size = 512;
        device: kernel.fs.IFile,

        interface: fatfs.Disk = fatfs.Disk{
            .getStatusFn = &getStatus,
            .initializeFn = &initialize,
            .readFn = &read,
            .writeFn = &write,
            .ioctlFn = &ioctl,
        },

        pub fn getStatus(self: *fatfs.Disk) fatfs.Disk.Status {
            _ = self;
            return .{
                .initialized = true,
                .disk_present = true,
                .write_protected = false,
            };
        }

        pub fn initialize(interface: *fatfs.Disk) fatfs.Disk.Error!fatfs.Disk.Status {
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            return getStatus(&self.interface);
        }

        pub fn read(interface: *fatfs.Disk, buff: [*]u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
            asm volatile ("cpsid i");
            defer asm volatile ("cpsie i");
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            const position = self.device.interface.seek(@as(c.off_t, @intCast(sector * sector_size)), c.SEEK_SET) catch return error.IoError;
            if (position < 0) return error.IoError;
            if (self.device.interface.read(buff[0 .. sector_size * count]) != sector_size * count) {
                return error.IoError;
            }
        }

        pub fn write(interface: *fatfs.Disk, buff: [*]const u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
            asm volatile ("cpsid i");
            defer asm volatile ("cpsie i");
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            log.debug("Writing to sector {d}, count {d}", .{ sector, count });
            const position = self.device.interface.seek(@as(c.off_t, @intCast(sector * sector_size)), c.SEEK_SET) catch return error.IoError;
            if (position < 0) return error.IoError;
            if (self.device.interface.write(buff[0 .. sector_size * count]) != sector_size * count) {
                return error.IoError;
            }
        }

        pub fn ioctl(interface: *fatfs.Disk, cmd: fatfs.IoCtl, buff: [*]u8) fatfs.Disk.Error!void {
            asm volatile ("cpsid i");
            defer asm volatile ("cpsie i");
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            switch (cmd) {
                .sync => {
                    // log.info("Syncing disk", .{self.device.interface.sync() catch |err| {
                    //     log.err("Failed to sync disk: {s}", .{@errorName(err)});
                    //     return error.IoError;
                    // }});
                },
                .get_sector_count => {
                    const size = self.device.interface.size();
                    @as(*align(1) fatfs.LBA, @ptrCast(buff)).* = @intCast(size >> 9);
                },
                else => {
                    log.err("invalid ioctl: {}", .{cmd});
                    return error.InvalidParameter;
                },
            }
        }
    };
});

pub fn create_fs_for_test() !kernel.fs.IFileSystem {
    const FatFsDeviceFileStub = @import("tests/device_stub.zig").FatFsDeviceFileStub;
    const device_file = try (try FatFsDeviceFileStub.InstanceType.create(std.testing.allocator, null)).interface.new(std.testing.allocator);
    return try (try FatFs.InstanceType.init(std.testing.allocator, device_file)).interface.new(std.testing.allocator);
}

test "FatFs.ShouldMountAfterFormat" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    const mount_result = fs.interface.mount();
    try std.testing.expectEqual(-1, mount_result);

    try fs.interface.format();
    try std.testing.expectEqual(0, fs.interface.mount());
}

test "FatFs.ShouldReturnCorrectName" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    const fs_name = fs.interface.name();
    try std.testing.expectEqualStrings("fatfs", fs_name);
}

fn create_write_and_verify(fs: *kernel.fs.IFileSystem, path: []const u8, data: []const u8) !void {
    try fs.interface.create(path, 0o644);
    var node = try fs.interface.get(path);
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    if (maybe_file) |*file| {
        const bytes_written = file.interface.write(data);
        try std.testing.expectEqual(@as(isize, @intCast(data.len)), bytes_written);

        // Seek back to beginning
        const seek_result = file.interface.seek(0, c.SEEK_SET);
        try std.testing.expectEqual(@as(c.off_t, 0), seek_result);

        // Read back the data
        var read_buffer = std.testing.allocator.alloc(u8, data.len) catch unreachable;
        defer std.testing.allocator.free(read_buffer);
        const bytes_read = file.interface.read(read_buffer);
        try std.testing.expectEqual(@as(isize, @intCast(data.len)), bytes_read);
        try std.testing.expectEqualStrings(data, read_buffer[0..@intCast(bytes_read)]);
    }
    // Delete the node to close the file
    node.delete();
}

test "FatFs.ShouldCreateFile" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try create_write_and_verify(&fs, "/test.txt", "Hello, FatFs!");
    // Remove the file
    try fs.interface.unlink("/test.txt");

    // Verify file no longer exists
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, fs.interface.get("/test.txt"));
}

test "FatFs.ShouldCreateDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Create root directory
    try fs.interface.mkdir("/testdir", 0o755);

    // Create nested directories
    try fs.interface.mkdir("/testdir/subdir1", 0o755);
    try fs.interface.mkdir("/testdir/subdir1/subdir2", 0o755);

    // Verify directories exist
    var node1 = try fs.interface.get("/testdir");
    defer node1.delete();
    try std.testing.expect(node1.is_directory());

    var node2 = try fs.interface.get("/testdir/subdir1");
    defer node2.delete();
    try std.testing.expect(node2.is_directory());

    var node3 = try fs.interface.get("/testdir/subdir1/subdir2");
    defer node3.delete();
    try std.testing.expect(node3.is_directory());

    // Write to files in different directories
    const test_data = [_]struct { path: []const u8, content: []const u8 }{
        .{ .path = "/testdir/file1.txt", .content = "Root level file" },
        .{ .path = "/testdir/subdir1/file2.txt", .content = "First nested file" },
        .{ .path = "/testdir/subdir1/subdir2/file3.txt", .content = "Deep nested file" },
    };

    for (test_data) |data| {
        try create_write_and_verify(&fs, data.path, data.content);
    }
}

test "FatFs.ShouldStatRootDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    var stat_buf: c.struct_stat = undefined;
    try fs.interface.stat("", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
    try std.testing.expectEqual(0, stat_buf.st_size);
}

test "FatFs.ShouldStatFile" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/test.txt", 0o644);

    var node = try fs.interface.get("/test.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var stat_buf: c.struct_stat = undefined;
    try fs.interface.stat("/test.txt", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFREG), stat_buf.st_mode);
}

test "FatFs.ShouldStatDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.mkdir("/testdir", 0o755);

    var stat_buf: c.struct_stat = undefined;
    try fs.interface.stat("/testdir", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
}

test "FatFs.ShouldStatNestedDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.mkdir("/parent", 0o755);
    try fs.interface.mkdir("/parent/child", 0o755);
    try fs.interface.mkdir("/parent/child/grandchild", 0o755);

    // Test stat for each level
    var stat_buf: c.struct_stat = undefined;

    try fs.interface.stat("/parent", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);

    try fs.interface.stat("/parent/child", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);

    try fs.interface.stat("/parent/child/grandchild", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
}

test "FatFs.ShouldAccessFile" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/test.txt", 0o644);

    // Test read access
    try fs.interface.access("/test.txt", c.R_OK, 0);

    // Test file existence
    try fs.interface.access("/test.txt", c.F_OK, 0);

    // Test non-existent file
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, fs.interface.access("/nonexistent.txt", c.F_OK, 0));
}

test "FatFs.ShouldAccessDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.mkdir("/testdir", 0o755);

    // Test directory access
    try fs.interface.access("/testdir", c.F_OK, 0);

    // Test write access on directory should fail with IsADirectory
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, fs.interface.access("/testdir", c.W_OK, 0));

    // Test execute access on directory should fail with IsADirectory
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, fs.interface.access("/testdir", c.X_OK, 0));
}

test "FatFs.ShouldRejectLinkOperation" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/old.txt", 0o644);

    // Link operation should not be supported
    try std.testing.expectError(error.NotSupported, fs.interface.link("/old.txt", "/new.txt"));
}

fn traverse_directory(fs: *kernel.fs.IFileSystem, path: []const u8, expectations: []const kernel.fs.DirectoryEntry) !void {
    var root_node = try fs.interface.get(path);
    defer root_node.delete();

    try std.testing.expect(root_node.is_directory());

    var maybe_dir = root_node.as_directory();
    try std.testing.expect(maybe_dir != null);

    if (maybe_dir) |*dir| {
        var iterator = try dir.interface.iterator();
        defer iterator.interface.delete();

        var found_entries = try std.ArrayList(kernel.fs.DirectoryEntry).initCapacity(std.testing.allocator, expectations.len);
        defer found_entries.deinit(std.testing.allocator);

        while (iterator.interface.next()) |entry| {
            const e = kernel.fs.DirectoryEntry{
                .name = try std.testing.allocator.dupe(u8, entry.name),
                .kind = entry.kind,
            };
            try found_entries.append(std.testing.allocator, e);
        }

        errdefer {
            for (found_entries.items) |found_entry| {
                std.testing.allocator.free(found_entry.name);
            }
        }

        for (expectations) |expected_entry| {
            var found = false;
            for (found_entries.items, 0..) |found_entry, i| {
                if (std.mem.eql(u8, expected_entry.name, found_entry.name) and
                    expected_entry.kind == found_entry.kind)
                {
                    const n = found_entries.orderedRemove(i);
                    std.testing.allocator.free(n.name);
                    found = true;
                    break;
                }
            }
            try std.testing.expect(found);
        }
        try std.testing.expectEqual(@as(usize, 0), found_entries.items.len);
    }
}

test "FatFs.ShouldIterateRootDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Create some files and directories in root
    try fs.interface.create("/file1.txt", 0o644);
    try fs.interface.create("/file2.txt", 0o644);
    try fs.interface.mkdir("/dir1", 0o755);
    try fs.interface.mkdir("/dir2", 0o755);

    const expected_entries: [4]kernel.fs.DirectoryEntry = [_]kernel.fs.DirectoryEntry{
        .{ .name = "file1.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "file2.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "dir1", .kind = kernel.fs.FileType.Directory },
        .{ .name = "dir2", .kind = kernel.fs.FileType.Directory },
    };
    try traverse_directory(&fs, "/", &expected_entries);
}

test "FatFs.ShouldIterateNestedDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Create nested structure
    try fs.interface.mkdir("/parent", 0o755);
    try fs.interface.create("/parent/file1.txt", 0o644);
    try fs.interface.create("/parent/file2.txt", 0o644);
    try fs.interface.create("/parent/file3.txt", 0o644);
    try fs.interface.mkdir("/parent/subdir1", 0o755);
    try fs.interface.mkdir("/parent/subdir2", 0o755);

    const expected_entries: [5]kernel.fs.DirectoryEntry = [_]kernel.fs.DirectoryEntry{
        .{ .name = "file1.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "file2.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "file3.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "subdir1", .kind = kernel.fs.FileType.Directory },
        .{ .name = "subdir2", .kind = kernel.fs.FileType.Directory },
    };
    try traverse_directory(&fs, "/parent", &expected_entries);
}

test "FatFs.ShouldIterateDeeplyNestedDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Create deeply nested structure
    try fs.interface.mkdir("/level1", 0o755);
    try fs.interface.mkdir("/level1/level2", 0o755);
    try fs.interface.mkdir("/level1/level2/level3", 0o755);
    try fs.interface.create("/level1/level2/level3/deep_file1.txt", 0o644);
    try fs.interface.create("/level1/level2/level3/deep_file2.txt", 0o644);
    try fs.interface.mkdir("/level1/level2/level3/deep_dir", 0o755);

    const expected_entries: [3]kernel.fs.DirectoryEntry = [_]kernel.fs.DirectoryEntry{
        .{ .name = "deep_file1.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "deep_file2.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "deep_dir", .kind = kernel.fs.FileType.Directory },
    };
    try traverse_directory(&fs, "/level1/level2/level3", &expected_entries);
}

test "FatFs.ShouldIterateEmptyDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.mkdir("/empty_dir", 0o755);

    var empty_node = try fs.interface.get("/empty_dir");
    defer empty_node.delete();

    try std.testing.expect(empty_node.is_directory());

    var maybe_dir = empty_node.as_directory();
    try std.testing.expect(maybe_dir != null);

    if (maybe_dir) |*dir| {
        var iterator = try dir.interface.iterator();
        defer iterator.interface.delete();

        var entry_count: usize = 0;
        while (iterator.interface.next()) |_| {
            entry_count += 1;
        }

        try std.testing.expectEqual(@as(usize, 0), entry_count);
    }
}

test "FatFs.ShouldSeekInFile" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    const test_data = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    try fs.interface.create("/seektest.txt", 0o644);
    var node = try fs.interface.get("/seektest.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        // Write test data
        const bytes_written = file.interface.write(test_data);
        try std.testing.expectEqual(@as(isize, @intCast(test_data.len)), bytes_written);

        // Test SEEK_SET - seek to beginning
        var pos = try file.interface.seek(0, c.SEEK_SET);
        try std.testing.expectEqual(@as(c.off_t, 0), pos);

        var buffer: [10]u8 = undefined;
        var bytes_read = file.interface.read(&buffer);
        try std.testing.expectEqual(@as(isize, 10), bytes_read);
        try std.testing.expectEqualStrings("0123456789", buffer[0..@intCast(bytes_read)]);

        // Test SEEK_SET - seek to position 20
        pos = try file.interface.seek(20, c.SEEK_SET);
        try std.testing.expectEqual(@as(c.off_t, 20), pos);

        bytes_read = file.interface.read(&buffer);
        try std.testing.expectEqual(@as(isize, 10), bytes_read);
        try std.testing.expectEqualStrings("KLMNOPQRST", buffer[0..@intCast(bytes_read)]);

        // Test SEEK_CUR - seek forward 5 bytes from current position (30)
        pos = try file.interface.seek(5, c.SEEK_CUR);
        try std.testing.expectEqual(@as(c.off_t, 35), pos);

        bytes_read = file.interface.read(buffer[0..2]);
        try std.testing.expectEqual(@as(isize, 1), bytes_read);
        try std.testing.expectEqualStrings("Z", buffer[0..@intCast(bytes_read)]);

        // Test SEEK_CUR - seek backward 10 bytes from current position (37)
        pos = try file.interface.seek(-10, c.SEEK_CUR);
        try std.testing.expectEqual(@as(c.off_t, 26), pos);

        bytes_read = file.interface.read(&buffer);
        try std.testing.expectEqual(@as(isize, 10), bytes_read);
        try std.testing.expectEqualStrings("QRSTUVWXY", buffer[0..9]);

        // Test SEEK_END - seek to end of file
        pos = try file.interface.seek(0, c.SEEK_END);
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), pos);

        // Test SEEK_END - seek 10 bytes before end
        pos = try file.interface.seek(-10, c.SEEK_END);
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len - 10)), pos);

        bytes_read = file.interface.read(&buffer);
        try std.testing.expectEqual(@as(isize, 10), bytes_read);
        try std.testing.expectEqualStrings("QRSTUVWXYZ", buffer[0..@intCast(bytes_read)]);

        // Test SEEK_CUR with 0 offset (should return current position without moving)
        pos = try file.interface.seek(0, c.SEEK_CUR);
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), pos);
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), file.interface.tell());

        // Test invalid seek (negative position with SEEK_SET)
        try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.interface.seek(-1, c.SEEK_SET));
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), file.interface.tell());

        // Test invalid seek (beyond end of file with SEEK_SET) - FatFS allows seeking beyond EOF
        // so we skip this test for FatFS

        // Test invalid seek whence
        try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.interface.seek(10, -123));
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), file.interface.tell());
    }
}

test "FatFs.ShouldReturnNotMemoryMapped" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/test.txt", 0o644);
    var node = try fs.interface.get("/test.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        var status: kernel.fs.FileMemoryMapAttributes = undefined;
        try std.testing.expectEqual(-1, file.interface.ioctl(-1, &status));
        try std.testing.expectEqual(0, file.interface.ioctl(@intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus), &status));
        try std.testing.expectEqual(false, status.is_memory_mapped);
    }
}

test "FatFs.ShouldReturnCorrectFileType" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Test file type
    try fs.interface.create("/test_file.txt", 0o644);
    var file_node = try fs.interface.get("/test_file.txt");
    defer file_node.delete();

    try std.testing.expectEqual(kernel.fs.FileType.File, file_node.filetype());
    try fs.interface.mkdir("/test_dir", 0o755);
    var dir_node = try fs.interface.get("/test_dir");
    defer dir_node.delete();

    try std.testing.expectEqual(kernel.fs.FileType.Directory, dir_node.filetype());
}

test "FatFs.ShouldAlwaysReturnZeroForFcntl" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/test.txt", 0o644);
    var node = try fs.interface.get("/test.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        var data: i32 = 0;
        try std.testing.expectEqual(0, file.interface.fcntl(-1, &data));
        try std.testing.expectEqual(0, data);
        try std.testing.expectEqual(0, file.interface.fcntl(-123, null));
        try std.testing.expectEqual(0, file.interface.fcntl(0, &data));
        try std.testing.expectEqual(0, file.interface.fcntl(999, null));
    }
}

test "FatFs.ShouldReturnCorrectFileSize" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Test empty file
    try fs.interface.create("/empty.txt", 0o644);
    var empty_node = try fs.interface.get("/empty.txt");
    defer empty_node.delete();

    try std.testing.expect(empty_node.is_file());
    if (empty_node.as_file()) |f| {
        try std.testing.expectEqual(0, f.interface.size());
    }

    // Test file with content
    const test_data = "Hello, FatFs! This is a test file.";
    try fs.interface.create("/test.txt", 0o644);
    var node = try fs.interface.get("/test.txt");
    defer node.delete();

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        _ = file.interface.write(test_data);
        try std.testing.expectEqual(test_data.len, file.interface.size());
    }

    // Re-open file and verify size persists
    node.delete();
    var reopened_node = try fs.interface.get("/test.txt");
    defer reopened_node.delete();
    if (reopened_node.as_file()) |f| {
        try std.testing.expectEqual(test_data.len, f.interface.size());
    }

    // Test large file
    const large_data = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(large_data);
    @memset(large_data, 'X');

    try fs.interface.create("/large.txt", 0o644);
    var large_node = try fs.interface.get("/large.txt");
    defer large_node.delete();

    var maybe_large_file = large_node.as_file();
    if (maybe_large_file) |*file| {
        _ = file.interface.write(large_data);
        try std.testing.expectEqual(4096, file.interface.size());
    }
}
