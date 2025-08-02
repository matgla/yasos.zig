//
// devicefs.zig
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

const ReadOnlyFileSystem = @import("../fs/ifilesystem.zig").ReadOnlyFileSystem;
const IDirectoryIterator = @import("../fs/ifilesystem.zig").IDirectoryIterator;
const IFile = @import("../fs/ifile.zig").IFile;

const IDriver = @import("idriver.zig").IDriver;

const interface = @import("interface");

const kernel = @import("../kernel.zig");
const c = @import("libc_imports").c;

const log = std.log.scoped(.@"vfs/driverfs");

const DriverDirectory = interface.DeriveFromBase(kernel.fs.ReadOnlyFile, struct {
    const Self = @This();
    base: kernel.fs.ReadOnlyFile,
    _allocator: std.mem.Allocator,
    _container: std.StringHashMap(IDriver),

    pub fn init(allocator: std.mem.Allocator) DriverDirectory {
        return DriverDirectory.init(.{
            .base = kernel.fs.ReadOnlyFile.init(.{}),
            ._allocator = allocator,
            ._container = std.StringHashMap(IDriver).init(allocator),
        });
    }

    pub fn deinit(self: *Self) void {
        log.debug("deinitialization", .{});
        var it = self._container.iterator();
        while (it.next()) |driver| {
            log.debug("removing driver: {s}", .{driver.value_ptr.interface.name()});
            driver.value_ptr.interface.delete();
        }
        self._container.deinit();
    }

    pub fn close(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn tell(self: *Self) c.off_t {
        _ = self;
        return 0;
    }

    pub fn size(self: *Self) isize {
        _ = self;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }

    pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
        _ = allocator;
        _ = self;
        return kernel.fs.FileName.init("/", null);
    }

    pub fn append(self: *Self, driver: IDriver, node_name: []const u8) !void {
        log.debug("mapping driver '{s}' to '{s}' ", .{ driver.interface.name(), node_name });
        self._container.put(node_name, driver) catch |err| {
            log.err("adding driver {s} failed with an error: {s}", .{ driver.interface.name(), @errorName(err) });
            return err;
        };
    }

    pub fn load_all(self: *Self) !void {
        log.debug("loading all drivers", .{});
        var it = self._container.iterator();
        while (it.next()) |driver| {
            driver.value_ptr.interface.load() catch |err| {
                log.err("Loading driver {s} failed with an error: {s}", .{ driver.value_ptr.interface.name(), @errorName(err) });
                return err;
            };
        }
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?IFile {
        if (self._container.getPtr(path)) |driver| {
            return driver.interface.ifile(allocator);
        }
        return null;
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        _ = self;
        _ = buffer;
        return 0;
    }

    pub fn write(self: *Self, buffer: []const u8) isize {
        _ = self;
        _ = buffer;
        return 0;
    }

    pub fn seek(self: *Self, offset: c.off_t, whence: i32) c.off_t {
        _ = self;
        _ = offset;
        _ = whence;
        return 0;
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        _ = self;
        _ = cmd;
        _ = data;
        return 0;
    }

    pub fn fcntl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        _ = self;
        _ = cmd;
        _ = data;
        return 0;
    }

    pub fn stat(self: *Self, buf: *c.struct_stat) void {
        _ = self;
        buf.st_dev = 0;
        buf.st_ino = 0;
        buf.st_mode = 0;
        buf.st_nlink = 0;
        buf.st_uid = 0;
        buf.st_gid = 0;
        buf.st_rdev = 0;
        buf.st_size = 0;
        buf.st_blksize = 1;
        buf.st_blocks = 1;
    }

    pub fn filetype(self: *Self) kernel.fs.FileType {
        _ = self;
        return kernel.fs.FileType.Directory;
    }

    pub fn iterator(self: *Self, path: []const u8) ?IDirectoryIterator {
        _ = path;
        return (kernel.driver.DriverFsIterator.InstanceType.create(self._container.iterator(), self._allocator)).interface.new(self._allocator) catch return null;
    }
});

pub const DriverFs = interface.DeriveFromBase(ReadOnlyFileSystem, struct {
    const Self = @This();
    base: ReadOnlyFileSystem,
    _allocator: std.mem.Allocator,
    _root: DriverDirectory,

    pub fn init(allocator: std.mem.Allocator) DriverFs {
        log.info("created", .{});
        return DriverFs.init(.{
            .base = ReadOnlyFileSystem.init(.{}),
            ._allocator = allocator,
            ._root = DriverDirectory.InstanceType.init(allocator),
        });
    }

    pub fn delete(self: *Self) void {
        self._root.data().deinit();
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "dev";
    }

    pub fn append(self: *Self, driver: IDriver, node_name: []const u8) !void {
        try self._root.data().append(driver, node_name);
    }

    pub fn load_all(self: *Self) !void {
        try self._root.data().load_all();
    }

    pub fn traverse(self: *Self, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
        _ = self;
        _ = path;
        _ = callback;
        _ = user_context;
        return -1;
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?IFile {
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return self._root.interface.new(self._allocator) catch return null;
        }
        return self._root.data().get(path, allocator);
    }

    pub fn has_path(self: *Self, path: []const u8) bool {
        _ = self;
        _ = path;
        return false;
    }

    pub fn iterator(self: *Self, path: []const u8) ?IDirectoryIterator {
        return self._root.data().iterator(path);
    }
});
