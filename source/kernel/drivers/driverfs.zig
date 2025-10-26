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
const IDirectoryIterator = @import("../fs/idirectory.zig").IDirectoryIterator;
const IFile = @import("../fs/ifile.zig").IFile;

const IDriver = @import("idriver.zig").IDriver;

const interface = @import("interface");

const kernel = @import("../kernel.zig");
const c = @import("libc_imports").c;

const log = std.log.scoped(.@"vfs/driverfs");

// const DriverNode = interface.DeriveFromBase(kernel.fs.Node, struct {
//     const Self = @This();
//     base: kernel.fs.INodeBase,
//     _idriver: ?*const IDriver,

//     pub fn create(allocator: std.mem.Allocator, idriver: ?*IDriver) !DriverNode {
//         var baseinit: kernel.fs.INodeBase = undefined;
//         if (idriver == null) {
//             const dir = try DriverDirectory.InstanceType.create(allocator).interface.new(allocator);
//             baseinit = kernel.fs.INodeBase.InstanceType.create_directory(dir);
//         } else {
//             baseinit = idriver.?.interface.inode().?;
//         }
//         return DriverNode.init(.{
//             .base = baseinit.*,
//             ._idriver = idriver,
//         });
//     }

//     pub fn name(self: *const Self) []const u8 {
//         return self._idriver.interface.name();
//     }

//     pub fn filetype(self: *Self) kernel.fs.FileType {
//         if (self._idriver == null) {
//             return kernel.fs.FileType.Directory;
//         }
//         return kernel.fs.FileType.File;
//     }
// });

const DriverDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    base: kernel.fs.ReadOnlyFile,
    _allocator: std.mem.Allocator,
    _container: std.StringHashMap(IDriver),

    var refcounter: i16 = 0;

    pub fn init(allocator: std.mem.Allocator) DriverDirectory {
        refcounter += 1;
        return DriverDirectory.init(.{
            .base = kernel.fs.ReadOnlyFile.init(.{}),
            ._allocator = allocator,
            ._container = std.StringHashMap(IDriver).init(allocator),
        });
    }

    pub fn __clone(self: *Self, other: *const Self) void {
        _ = self;
        _ = other;
        @panic("DriverDirectory can't be cloned");
    }

    pub fn delete(self: *Self) void {
        refcounter -= 1;
        if (refcounter > 0) {
            return;
        }
        var it = self._container.iterator();

        while (it.next()) |driver| {
            log.debug("removing driver: {s}", .{driver.value_ptr.interface.name()});
            driver.value_ptr.interface.delete();
        }
        self._container.deinit();
    }

    pub fn close(self: *Self) void {
        self.delete();
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

    pub fn get(self: *Self, path: []const u8, result: *kernel.fs.Node) anyerror!void {
        if (self._container.getPtr(path)) |driver| {
            result.* = try driver.interface.node();
            return;
        }
        return error.NoEntry;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "dev";
    }

    pub fn iterator(self: *const Self) anyerror!IDirectoryIterator {
        return try (kernel.driver.DriverFsIterator.InstanceType.create(self._container.iterator(), self._allocator)).interface.new(self._allocator);
    }
});

pub const DriverFs = interface.DeriveFromBase(ReadOnlyFileSystem, struct {
    const Self = @This();
    base: ReadOnlyFileSystem,
    _allocator: std.mem.Allocator,
    _root: kernel.fs.IDirectory,

    fn get_root_directory(self: *Self) *DriverDirectory.InstanceType {
        return self._root.as(DriverDirectory.InstanceType);
    }

    pub fn init(allocator: std.mem.Allocator) !DriverFs {
        log.info("created", .{});
        return DriverFs.init(.{
            .base = ReadOnlyFileSystem.init(.{}),
            ._allocator = allocator,
            ._root = try DriverDirectory.InstanceType.init(allocator).interface.new(allocator),
        });
    }

    pub fn delete(self: *Self) void {
        self._root.interface.delete();
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "dev";
    }

    pub fn append(self: *Self, driver: IDriver, node_name: []const u8) !void {
        try self.get_root_directory().append(driver, node_name);
    }

    pub fn load_all(self: *Self) !void {
        try self.get_root_directory().load_all();
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?kernel.fs.Node {
        _ = allocator;
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            const root_clone = self._root.share();
            return kernel.fs.Node.create_directory(root_clone);
        }
        var result: kernel.fs.Node = undefined;
        self.get_root_directory().get(path, &result) catch return null;
        return result;
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self;
        return error.NotSupported; // Driver directory cannot be formatted
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat) i32 {
        var maybe_node = self.get(path, self._allocator);
        if (maybe_node) |*node| {
            defer node.delete();
            data.st_blksize = 1;
            data.st_rdev = 1;
            if (node.is_directory()) {
                data.st_mode = c.S_IFDIR;
            } else if (node.is_file()) {
                data.st_mode = c.S_IFREG;
            }
            return 0;
        }
        return -1; // Stat not supported for driverfs
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = old_path;
        _ = new_path;
        return error.NotSupported;
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        _ = self;
        _ = path;
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

        if ((mode & c.X_OK) != 0) {
            return kernel.errno.ErrnoSet.PermissionDenied;
        }

        if ((mode & c.W_OK) != 0) {
            return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
        }
        return 0;
    }
});
