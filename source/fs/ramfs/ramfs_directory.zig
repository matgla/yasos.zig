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
const refcount = kernel.sync.refcount;

/// State every handle on one directory shares.
///
/// The refcount and the timestamps travel together because `__clone` copies the
/// handle struct wholesale: anything a second handle must see a first handle's
/// change to has to live behind a pointer, and folding the timestamps into the
/// refcounter's allocation keeps a directory at the two allocations it already
/// cost.
const SharedState = struct {
    refcounter: i16,
    times: kernel.fs.FileTimes,
};

pub const RamFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _root: *std.DoublyLinkedList,
    _shared: *SharedState,
    _name: []const u8,

    pub fn create(allocator: std.mem.Allocator, nodename: []const u8) !RamFsDirectory {
        const list = try allocator.create(std.DoublyLinkedList);
        const shared = try allocator.create(SharedState);
        shared.times = kernel.fs.FileTimes.create(kernel.time.now_timespec());
        refcount.init(&shared.refcounter);
        list.* = std.DoublyLinkedList{};
        return RamFsDirectory.init(.{
            ._allocator = allocator,
            ._root = list,
            ._name = nodename,
            ._shared = shared,
        });
    }

    /// This directory's shared timestamps, for `stat` and `utimens`.
    pub fn times(self: *Self) *kernel.fs.FileTimes {
        return &self._shared.times;
    }

    pub fn __clone(self: *Self, other: *const Self) void {
        self.* = other.*;
        refcount.acquire(&self._shared.refcounter);
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

    /// The entry named `nodename`, borrowed -- no clone, and so no allocation.
    /// `get` hands back an owned Node, which costs one: right for `open`, whose
    /// handle needs its own file position, and wrong on a tiered /tmp, where the
    /// allocator is the arena and `unlink` has to work once it is full.
    pub fn get_node(self: *Self, nodename: []const u8) ?*RamFsNode {
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
        // Adding an entry rewrites the directory, so both its modification and
        // its change time move -- the same rule a real filesystem follows, and
        // what lets `make` see that a directory gained a file.
        self._shared.times.record_write(kernel.time.now_timespec());
    }

    pub fn unlink(self: *Self, nodename: []const u8) anyerror!void {
        const maybe_node = self.get_node(nodename);
        if (maybe_node) |node| {
            if (node.node.as_directory()) |directory| {
                // Read the child's entry list directly rather than through an
                // iterator: `iterator()` allocates, and removal must not need
                // memory -- on a tiered /tmp that comes from the arena.
                var child_directory = directory;
                if (child_directory.as(RamFsDirectory).data()._root.first != null) {
                    return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
                }
            }
            // Unlink from the list BEFORE destroying the node: `node.delete`
            // frees the RamFsNode, and `list_node` is a field inside it, so the
            // other order reads freed memory to find its neighbours.
            self._root.remove(&node.list_node);
            node.delete(self._allocator);
            self._shared.times.record_write(kernel.time.now_timespec());
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
        if (refcount.release(&self._shared.refcounter)) {
            var next = self._root.pop();
            while (next) |child| {
                const file_node: *RamFsNode = @fieldParentPtr("list_node", child);
                file_node.delete(self._allocator);
                next = self._root.pop();
            }
            self._allocator.destroy(self._root);
            self._allocator.destroy(self._shared);
        }
    }
});
