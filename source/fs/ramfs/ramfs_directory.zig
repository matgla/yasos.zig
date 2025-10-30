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

const kernel = @import("kernel");
const interface = @import("interface");

const RamFsDirectoryIterator = @import("ramfs_directory_iterator.zig").RamFsDirectoryIterator;
const RamFsNode = @import("ramfs_node.zig").RamFsNode;

const log = std.log.scoped(.ramfsdirectory);

pub const RamFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _root: *std.DoublyLinkedList,
    _refcounter: *i16,
    _name: []const u8,

    pub fn create(allocator: std.mem.Allocator, nodename: []const u8) !RamFsDirectory {
        const list = try allocator.create(std.DoublyLinkedList);
        const refcounter = try allocator.create(i16);
        refcounter.* = 1;
        list.* = std.DoublyLinkedList{};
        return RamFsDirectory.init(.{
            ._allocator = allocator,
            ._root = list,
            ._name = nodename,
            ._refcounter = refcounter,
        });
    }

    pub fn __clone(self: *Self, other: *const Self) void {
        self.* = other.*;
        self._refcounter.* += 1;
    }

    pub fn create_node(allocator: std.mem.Allocator, nodename: []const u8) anyerror!kernel.fs.Node {
        const dir = try (try create(allocator, nodename)).interface.new(allocator);
        return kernel.fs.Node.create_directory(dir);
    }

    pub fn get(self: *Self, dirname: []const u8, node: *kernel.fs.Node) anyerror!void {
        var it = self._root.first;
        while (it) |child| : (it = child.next) {
            const file_node: *RamFsNode = @fieldParentPtr("list_node", child);
            if (std.mem.eql(u8, file_node.node.name(), dirname)) {
                node.* = try file_node.node.clone();
                return;
            }
        }

        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn get_node(self: *Self, nodename: []const u8) ?*RamFsNode {
        var it = self._root.first;
        while (it) |child| : (it = child.next) {
            const file_node: *RamFsNode = @fieldParentPtr("list_node", child);
            if (std.mem.eql(u8, file_node.node.name(), nodename)) {
                return file_node;
            }
        }
        return null;
    }

    pub fn append(self: *Self, node: *RamFsNode) !void {
        self._root.append(&node.list_node);
    }

    pub fn unlink(self: *Self, nodename: []const u8) anyerror!void {
        const maybe_node = self.get_node(nodename);
        if (maybe_node) |node| {
            if (node.node.as_directory()) |*dir| {
                var dir_it = try dir.interface.iterator();
                defer dir_it.interface.delete();
                if (dir_it.interface.next() != null) {
                    return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
                }
            }
            node.delete(self._allocator);
            self._root.remove(&node.list_node);
            return;
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        return try RamFsDirectoryIterator.InstanceType.create(self._root).interface.new(self._allocator);
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn delete(self: *Self) void {
        self._refcounter.* -= 1;
        if (self._refcounter.* == 0) {
            var next = self._root.pop();
            while (next) |child| {
                const file_node: *RamFsNode = @fieldParentPtr("list_node", child);
                file_node.delete(self._allocator);
                next = self._root.pop();
            }
            self._allocator.destroy(self._root);
            self._allocator.destroy(self._refcounter);
        }
    }
});
