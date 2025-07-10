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

const log = std.log.scoped(.@"vfs/driverfs");

pub const DriverFs = struct {
    pub usingnamespace interface.DeriveFromBase(ReadOnlyFileSystem, DriverFs);
    base: ReadOnlyFileSystem,
    _allocator: std.mem.Allocator,
    _container: std.StringHashMap(IDriver),

    pub fn init(allocator: std.mem.Allocator) DriverFs {
        log.info("created", .{});
        return .{
            .base = ReadOnlyFileSystem{},
            ._allocator = allocator,
            ._container = std.StringHashMap(IDriver).init(allocator),
        };
    }

    pub fn delete(self: *DriverFs) void {
        log.debug("deinitialization", .{});
        var it = self._container.iterator();
        while (it.next()) |driver| {
            driver.value_ptr.delete();
        }
        self._container.deinit();
        self._allocator.destroy(self);
    }

    pub fn name(self: *const DriverFs) []const u8 {
        _ = self;
        return "drivers";
    }

    pub fn append(self: *DriverFs, driver: IDriver, node_name: []const u8) !void {
        log.debug("mapping driver '{s}' to '{s}' ", .{ driver.name(), node_name });
        self._container.put(node_name, driver) catch |err| {
            log.err("adding driver {s} failed with an error: {s}", .{ driver.name(), @errorName(err) });
            return err;
        };
    }

    pub fn load_all(self: *DriverFs) !void {
        log.debug("loading all drivers", .{});
        var it = self._container.iterator();
        while (it.next()) |driver| {
            driver.value_ptr.load() catch |err| {
                log.err("Loading driver {s} failed with an error: {s}", .{ driver.value_ptr.name(), @errorName(err) });
                return err;
            };
        }
    }

    pub fn traverse(self: *DriverFs, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
        _ = self;
        _ = path;
        _ = callback;
        _ = user_context;
        return -1;
    }

    pub fn get(self: *DriverFs, path: []const u8) ?IFile {
        if (self._container.getPtr(path)) |driver| {
            return driver.ifile();
        }
        return null;
    }

    pub fn has_path(self: *const DriverFs, path: []const u8) bool {
        _ = self;
        _ = path;
        return false;
    }

    pub fn iterator(self: *DriverFs, path: []const u8) ?IDirectoryIterator {
        _ = self;
        _ = path;
        return null;
    }
};
