// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const interface = @import("interface");
const fatfs = @import("zfat");

const kernel = @import("kernel");

pub const FatFsIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    const Self = @This();
    _dir: fatfs.Dir,
    _allocator: std.mem.Allocator,

    pub fn create(dir: fatfs.Dir, allocator: std.mem.Allocator) FatFsIterator {
        return FatFsIterator.init(.{
            ._dir = dir,
            ._allocator = allocator,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.DirectoryEntry {
        const maybe_entry = self._dir.next() catch return null;
        if (maybe_entry) |entry| {
            return .{
                .name = entry.name(),
                .kind = if (entry.kind == .Directory) .Directory else .File,
            };
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        self._dir.close();
    }
});

pub const FatFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    _allocator: std.mem.Allocator,
    _name: []const u8,
    _path: [:0]const u8,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, path: [:0]const u8) !FatFsDirectory {
        const maybe_stat: ?fatfs.FileInfo = fatfs.stat(path) catch null;
        var dirname: []const u8 = undefined;
        if (maybe_stat) |stat| {
            dirname = try allocator.dupe(u8, stat.name());
        } else {
            dirname = try allocator.dupe(u8, "");
        }
        return FatFsDirectory.init(.{
            ._allocator = allocator,
            ._name = dirname,
            ._path = try allocator.dupeZ(u8, path),
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, path: [:0]const u8) !kernel.fs.Node {
        const dir = try (try create(allocator, path)).interface.new(allocator);
        return kernel.fs.Node.create_directory(dir);
    }

    pub fn get(self: *Self, nodename: []const u8, node: *kernel.fs.Node) anyerror!void {
        _ = nodename;
        _ = self;
        _ = node;
        return error.NotImplemented;
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        var dir = try fatfs.Dir.open(self._path);
        return FatFsIterator.InstanceType.create(dir, self._allocator).interface.new(self._allocator) catch {
            dir.close();
            return error.OutOfMemory;
        };
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn close(self: *Self) void {
        _ = self;
    }

    pub fn delete(self: *Self) void {
        self.close();
        self._allocator.free(self._name);
        self._allocator.free(self._path);
    }
});
