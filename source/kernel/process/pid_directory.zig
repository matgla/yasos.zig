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

const kernel = @import("../kernel.zig");

const log = std.log.scoped(.@"vfs/procfs/pid_directory");

const PidStatFile = @import("pidstat_file.zig").PidStatFile;

const PidIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    pub const Self = @This();
    _index: usize,
    _items: []const []const u8,

    pub fn create() PidIterator {
        return PidIterator.init(.{
            ._index = 0,
            ._items = &.{
                "stat",
                "status",
            },
        });
    }

    pub fn next(self: *Self) ?kernel.fs.DirectoryEntry {
        if (self._index >= self._items.len) {
            return null;
        }
        const entry = kernel.fs.DirectoryEntry{
            .name = self._items[self._index],
            .kind = kernel.fs.FileType.File,
        };
        self._index += 1;
        return entry;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

pub const PidDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _name_buffer: [16]u8,
    _name: []const u8,
    _pid: i16,

    pub fn create(allocator: std.mem.Allocator, pid: i16) !PidDirectory {
        var dir = PidDirectory.init(.{
            ._allocator = allocator,
            ._name_buffer = undefined,
            ._name = undefined,
            ._pid = pid,
        });
        dir.data()._name = try std.fmt.bufPrint(&dir.data()._name_buffer, "{d}", .{pid});
        return dir;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }

    pub fn create_node(allocator: std.mem.Allocator, pid: i16) anyerror!kernel.fs.Node {
        const dir = try (try create(allocator, pid)).interface.new(allocator);
        return kernel.fs.Node.create_directory(dir);
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn get(self: *Self, nodename: []const u8, result: *kernel.fs.Node) anyerror!void {
        if (std.mem.eql(u8, "stat", nodename)) {
            result.* = try PidStatFile.InstanceType.create_node(self._allocator, self._pid, false);
            return;
        }
        if (std.mem.eql(u8, "status", nodename)) {
            result.* = try PidStatFile.InstanceType.create_node(self._allocator, self._pid, true);
            return;
        }

        return error.NodeNotFound;
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        // var pidmap: ?@TypeOf(kernel.process.process_manager.instance).PidMap = null;
        // if (self._is_root) {
        //     pidmap = kernel.process.process_manager.instance.get_pidmap();
        // }
        // return ProcFsIterator.InstanceType.create(self._allocator, self._data._nodes.items, pidmap).interface.new(self._allocator);
        return PidIterator.InstanceType.create().interface.new(self._allocator);
    }
});
