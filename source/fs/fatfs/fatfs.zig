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

var global_fs: fatfs.FileSystem = undefined;
var buffer: [4096]u8 = undefined;

const FatFsIterator = oop.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    const Self = @This();
    _dir: fatfs.Dir,
    _allocator: std.mem.Allocator,
    _path: [:0]const u8,

    pub fn create(dir: fatfs.Dir, allocator: std.mem.Allocator, path: [:0]const u8) FatFsIterator {
        return FatFsIterator.init(.{
            ._dir = dir,
            ._allocator = allocator,
            ._path = path,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.IFile {
        const maybe_entry = self._dir.next() catch return null;
        if (maybe_entry) |entry| {
            const path = std.fmt.allocPrintSentinel(self._allocator, "{s}/{s}", .{ self._path, entry.name() }, 0) catch {
                return null;
            };
            log.debug("Next entry: {s}", .{path});
            const maybe_file = FatFsFile.InstanceType.create(self._allocator, path);
            if (maybe_file) |*file| {
                return file.interface.new(self._allocator) catch {
                    self._allocator.free(path);
                    return null;
                };
            }
        } else {
            log.debug("No more entries in directory: {s}", .{self._path});
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        self._allocator.free(self._path);
    }
});

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
                .device = d.share(),
            },
        });
    }

    pub fn iterator(self: *Self, path: []const u8) ?kernel.fs.IDirectoryIterator {
        log.debug("Creating iterator for path: {s}", .{path});
        const p: [:0]const u8 = self._allocator.dupeZ(u8, path) catch {
            log.err("Failed to allocate memory for path: {s}", .{path});
            return null;
        };

        return FatFsIterator.InstanceType.create(
            fatfs.Dir.open(p) catch return null,
            self._allocator,
            p,
        ).interface.new(self._allocator) catch {
            return null;
        };
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

    pub fn create(self: *Self, path: []const u8, _: i32, allocator: std.mem.Allocator) ?kernel.fs.IFile {
        log.info("Creating file at path: {s}", .{path});
        const filepath = allocator.dupeZ(u8, path) catch {
            log.err("Failed to allocate memory for path: {s}", .{path});
            return null;
        };
        defer allocator.free(filepath);
        _ = fatfs.File.create(filepath) catch |err| {
            log.err("Failed to create file: {s}", .{@errorName(err)});
            return null;
        };
        return self.get(path, allocator);
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

    pub fn remove(self: *Self, path: []const u8) i32 {
        log.info("Removing file or directory at path: {s}", .{path});
        const filepath = self._allocator.dupeZ(u8, path) catch {
            log.err("Failed to allocate memory for path: {s}", .{path});
            return -1;
        };
        defer self._allocator.free(filepath);
        fatfs.unlink(filepath) catch |err| {
            log.err("Failed to remove file or directory: {s}", .{@errorName(err)});
            return -1;
        };
        return -1;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "fatfs";
    }

    pub fn traverse(self: *Self, path: []const u8, callback: *const fn (file: *kernel.fs.IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
        _ = self;
        _ = path;
        _ = callback;
        _ = user_context;
        return -1;
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?kernel.fs.IFile {
        _ = self;
        // const path_without_leading_slash: [:0]const u8 = std.mem.trimStart(u8, path, "\\/");
        // const filepath = std.fmt.allocPrintZ(allocator, "0:/{s}", .{path_without_leading_slash}) catch {
        // log.err("Failed to allocate memory for path: {s}", .{path_without_leading_slash});
        // return null;
        // };
        const filepath = allocator.dupeZ(u8, path) catch {
            log.err("Failed to allocate memory for path: {s}", .{path});
            return null;
        };
        var maybe_file = FatFsFile.InstanceType.create(allocator, filepath);
        if (maybe_file) |*file| {
            return file.interface.new(allocator) catch return null;
        } else {
            allocator.free(filepath);
            return null;
        }
    }

    pub fn has_path(self: *Self, path: []const u8) bool {
        var maybe_file = self.get(path, self._allocator);
        if (maybe_file) |*file| {
            _ = file.interface.close();
            return true;
        }
        return false;
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
            if (self.device.interface.seek(@as(c.off_t, @intCast(sector * sector_size)), c.SEEK_SET) < 0) return error.IoError;
            if (self.device.interface.write(buff[0 .. sector_size * count]) != sector_size * count) {
                return error.IoError;
            }
        }

        pub fn ioctl(interface: *fatfs.Disk, cmd: fatfs.IoCtl, buff: [*]u8) fatfs.Disk.Error!void {
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            switch (cmd) {
                .sync => {},
                .get_sector_count => {
                    @as(*align(1) fatfs.LBA, @ptrCast(buff)).* = @intCast(self.device.interface.size() >> 9);
                },
                else => {
                    log.err("invalid ioctl: {}", .{cmd});
                    return error.InvalidParameter;
                },
            }
        }
    };
});
