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

pub const DriverFs = struct {
    pub usingnamespace interface.DeriveFromBase(ReadOnlyFileSystem, DriverFs);
    base: ReadOnlyFileSystem,
    _allocator: std.mem.Allocator,
    _container: std.ArrayList(IDriver),

    pub fn init(allocator: std.mem.Allocator) DriverFs {
        return .{
            .base = ReadOnlyFileSystem{},
            ._allocator = allocator,
            ._container = std.ArrayList(IDriver).init(allocator),
        };
    }

    pub fn delete(self: *DriverFs) void {
        for (self._container.items) |*driver| {
            driver.delete();
        }
        self._container.deinit();
        self._allocator.destroy(self);
    }

    pub fn name(self: *const DriverFs) []const u8 {
        _ = self;
        return "drivers";
    }

    pub fn append(self: *DriverFs, driver: IDriver) !void {
        try self._container.append(driver);
    }

    pub fn load_all(self: *DriverFs) !void {
        for (self._container.items) |*driver| {
            try driver.load();
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
        _ = self;
        _ = path;
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
