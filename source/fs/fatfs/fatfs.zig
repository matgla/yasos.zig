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

var global_fs: fatfs.FileSystem = undefined;
var buffer: [4096]u8 = undefined;

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

    pub fn mkdir(self: *Self, path: []const u8, _: i32) i32 {
        log.info("Creating directory at path: {s}", .{path});
        const filepath = self._allocator.dupeZ(u8, path) catch {
            log.err("Failed to allocate memory for path: {s}", .{path});
            return -1;
        };
        defer self._allocator.free(filepath);
        _ = fatfs.mkdir(filepath) catch |err| {
            log.err("Failed to create directory: {s}", .{@errorName(err)});
            return -1;
        };
        return -1;
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

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        _ = self;
        const filepath = try allocator.dupeZ(u8, path);
        defer allocator.free(filepath);

        var dir: ?fatfs.Dir = fatfs.Dir.open(filepath) catch blk: {
            break :blk null;
        };

        if (dir) |*d| {
            d.close();
            return try FatFsDirectory.InstanceType.create_node(allocator, filepath);
        }
        return try FatFsFile.InstanceType.create_node(allocator, filepath);
    }

    pub fn format(self: *Self) anyerror!void {
        log.info("Formatting FAT filesystem", .{});

        fatfs.disks[0] = &self._disk_wrapper.interface;
        fatfs.mkfs(
            "0:",
            .{ .filesystem = .fat32, .sector_align = 1, .use_partitions = false },
            &buffer,
        ) catch |err| {
            log.err("Failed to format FAT filesystem: {s}", .{@errorName(err)});
            return err;
        };
        _ = self.umount();
        _ = self.mount();
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat) i32 {
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
            return 0;
        }
        var path_c = std.fmt.allocPrintSentinel(self._allocator, "0:/{s} ", .{path}, 0) catch {
            log.err("Failed to allocate memory for path: {s}", .{path});
            return -1;
        };
        path_c[path_c.len - 1] = 0; // Null-terminate
        defer self._allocator.free(path_c);
        const finfo = fatfs.stat(path_c) catch |err| {
            log.err("Failed to stat path: '{s}', with an error: {s}", .{ path_c, @errorName(err) });
            return -1;
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
        return 0;
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = old_path;
        _ = new_path;
        return error.NotSupported;
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!i32 {
        _ = flags;
        var maybe_node = self.get(path, self._allocator);
        defer if (maybe_node) |*n| n.delete();
        if ((mode & c.F_OK) != 0) {
            if (maybe_node == null) {
                return kernel.errno.ErrnoSet.NoEntry;
            }
        }

        if (maybe_node) |*node| {
            if ((mode & c.W_OK) != 0 or (mode & c.X_OK) != 0) {
                if (node.filetype() == kernel.fs.FileType.Directory) {
                    return kernel.errno.ErrnoSet.IsADirectory;
                }
            }
        }
        return 0;
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
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            if (self.device.interface.seek(@as(c.off_t, @intCast(sector * sector_size)), c.SEEK_SET) < 0) return error.IoError;
            if (self.device.interface.read(buff[0 .. sector_size * count]) != sector_size * count) {
                return error.IoError;
            }
        }

        pub fn write(interface: *fatfs.Disk, buff: [*]const u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            log.debug("Writing to sector {d}, count {d}", .{ sector, count });
            if (self.device.interface.seek(@as(c.off_t, @intCast(sector * sector_size)), c.SEEK_SET) < 0) return error.IoError;
            if (self.device.interface.write(buff[0 .. sector_size * count]) != sector_size * count) {
                return error.IoError;
            }
        }

        pub fn ioctl(interface: *fatfs.Disk, cmd: fatfs.IoCtl, buff: [*]u8) fatfs.Disk.Error!void {
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            switch (cmd) {
                .sync => {
                    // log.info("Syncing disk", .{self.device.interface.sync() catch |err| {
                    //     log.err("Failed to sync disk: {s}", .{@errorName(err)});
                    //     return error.IoError;
                    // }});
                },
                .get_sector_count => {
                    // log.debug("Getting sector count: {d}", .{@as(i32, @intCast(self.device.interface.size() >> 9))});
                    var st: c.struct_stat = undefined;
                    self.device.interface.stat(&st);
                    @as(*align(1) fatfs.LBA, @ptrCast(buff)).* = @intCast(st.st_size >> 9);
                },
                else => {
                    log.err("invalid ioctl: {}", .{cmd});
                    return error.InvalidParameter;
                },
            }
        }
    };
});
