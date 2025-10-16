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

pub const ProcFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _nodes: std.ArrayList(kernel.fs.Node),
    _name: []const u8,

    pub fn create(allocator: std.mem.Allocator, dirname: []const u8) !ProcFsDirectory {
        return ProcFsDirectory.init(.{
            ._allocator = allocator,
            ._nodes = try std.ArrayList(kernel.fs.Node).initCapacity(allocator, 16),
            ._name = dirname,
        });
    }

    pub fn delete(self: *Self) void {
        for (self._nodes.items) |*node| {
            node.delete();
        }
        self._nodes.deinit(self._allocator);
    }

    pub fn create_node(allocator: std.mem.Allocator, dirname: []const u8) anyerror!kernel.fs.Node {
        const dir = try (try create(allocator, dirname)).interface.new(allocator);
        return kernel.fs.Node.create_directory(dir);
    }

    pub fn append(self: *Self, node: kernel.fs.Node) !void {
        try self._nodes.append(self._allocator, node);
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn close(self: *Self) void {
        _ = self;
    }

    pub fn get(self: *Self, nodename: []const u8, result: *kernel.fs.Node) anyerror!void {
        for (self._nodes.items) |*node| {
            if (std.mem.eql(u8, node.name(), nodename)) {
                try node.sync();
                result.* = try node.clone();
                return;
            }
        }
        return error.NodeNotFound;
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        return ProcFsIterator.InstanceType.create(self._nodes.items).interface.new(self._allocator);
    }
});
