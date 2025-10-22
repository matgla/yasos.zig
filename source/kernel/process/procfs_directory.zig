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

const ProcFsIterator = @import("procfs_iterator.zig").ProcFsIterator;
const PidDirectory = @import("pid_directory.zig").PidDirectory;

const log = std.log.scoped(.@"vfs/procfs/directory");

const ProcFsDirectoryData = struct {
    const Self = @This();
    _nodes: std.ArrayList(kernel.fs.Node),
    _name: []const u8,
    _refcounter: i16,

    pub fn share(self: *Self) *Self {
        self._refcounter += 1;
        return self;
    }

    pub fn delete(self: *Self, allocator: std.mem.Allocator) void {
        self._refcounter -= 1;
        if (self._refcounter == 0) {
            for (self._nodes.items) |*node| {
                node.delete();
            }
            self._nodes.deinit(allocator);
            // allocator.free(self._name);
            allocator.destroy(self);
        }
    }
};

pub const ProcFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _data: *ProcFsDirectoryData,
    _is_root: bool,

    pub fn create(allocator: std.mem.Allocator, dirname: []const u8, is_root: bool) !ProcFsDirectory {
        const data = try allocator.create(ProcFsDirectoryData);
        errdefer allocator.destroy(data);

        data.* = .{
            ._nodes = try std.ArrayList(kernel.fs.Node).initCapacity(allocator, 4),
            ._name = dirname,
            ._refcounter = 1,
        };

        return ProcFsDirectory.init(.{
            ._allocator = allocator,
            ._data = data,
            ._is_root = is_root,
        });
    }

    pub fn __clone(self: *Self, other: *Self) void {
        self._allocator = other._allocator;
        self._data = other._data.share();
    }

    pub fn delete(self: *Self) void {
        self._data.delete(self._allocator);
    }

    pub fn create_node(allocator: std.mem.Allocator, dirname: []const u8, is_root: bool) anyerror!kernel.fs.Node {
        const dir = try (try create(allocator, dirname, is_root)).interface.new(allocator);
        return kernel.fs.Node.create_directory(dir);
    }

    pub fn append(self: *Self, node: kernel.fs.Node) !void {
        try self._data._nodes.append(self._allocator, node);
    }

    pub fn name(self: *const Self) []const u8 {
        return self._data._name;
    }

    pub fn close(self: *Self) void {
        _ = self;
    }

    pub fn get(self: *Self, nodename: []const u8, result: *kernel.fs.Node) anyerror!void {
        if (self._is_root) {
            const maybe_pid: ?i16 = std.fmt.parseInt(i16, nodename, 10) catch null;
            if (maybe_pid) |pid| {
                if (pid == 0) {
                    // skip PID 0, this is not a valid process (supervisor mode in CPU only)
                    return error.NodeNotFound;
                }
                result.* = try PidDirectory.InstanceType.create_node(self._allocator, pid);
                return;
            }
        }
        for (self._data._nodes.items) |*node| {
            if (std.mem.eql(u8, node.name(), nodename)) {
                try node.sync();
                result.* = try node.clone();
                return;
            }
        }
        return error.NodeNotFound;
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        var pidmap: ?@TypeOf(kernel.process.process_manager.instance).PidMap = null;
        if (self._is_root) {
            pidmap = kernel.process.process_manager.instance.get_pidmap();
        }
        return ProcFsIterator.InstanceType.create(self._allocator, self._data._nodes.items, pidmap).interface.new(self._allocator);
    }
});
