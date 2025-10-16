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
const RamFsData = @import("ramfs_data.zig").RamFsData;
const RamFsNode = @import("ramfs_node.zig").RamFsNode;

const log = std.log.scoped(.ramfsdirectory);

pub const RamFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    var refcounter: i16 = 0;
    const Self = @This();
    _allocator: std.mem.Allocator,
    _root: *std.DoublyLinkedList,
    _name: []const u8,

    pub fn create(allocator: std.mem.Allocator, nodename: []const u8) !RamFsDirectory {
        refcounter += 1;
        const list = try allocator.create(std.DoublyLinkedList);
        list.* = std.DoublyLinkedList{};
        return RamFsDirectory.init(.{
            ._allocator = allocator,
            ._root = list,
            ._name = try allocator.dupe(u8, nodename),
        });
    }

    pub fn __clone(self: *Self, other: *const Self) void {
        self.* = other.*;
        refcounter += 1;
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

    pub fn append(self: *Self, node: kernel.fs.Node) !void {
        const file_node = try self._allocator.create(RamFsNode);
        file_node.* = RamFsNode{
            .node = node,
            .list_node = std.DoublyLinkedList.Node{},
        };
        self._root.append(&file_node.list_node);
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        return try RamFsDirectoryIterator.InstanceType.create(self._root).interface.new(self._allocator);
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn close(self: *Self) void {
        _ = self;
    }

    pub fn delete(self: *Self) void {
        refcounter -= 1;
        if (refcounter == 0) {
            log.err("Deleting directory: {s}", .{self._name});
            var it = self._root.first;
            while (it) |child| : (it = child.next) {
                const file_node: *RamFsNode = @fieldParentPtr("list_node", child);
                file_node.node.delete();
                self._allocator.destroy(file_node);
                self._allocator.destroy(self._root);
            }
            self._allocator.free(self._name);
        }
    }
});
