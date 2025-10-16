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

const kernel = @import("kernel");

const RamFsNode = @import("ramfs_node.zig").RamFsNode;

pub const RamFsDirectoryIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    const Self = @This();
    _current: ?*std.DoublyLinkedList.Node,

    pub fn create(node: *std.DoublyLinkedList) RamFsDirectoryIterator {
        return RamFsDirectoryIterator.init(.{
            ._current = node.first,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.DirectoryEntry {
        if (self._current) |current| {
            const file: *RamFsNode = @fieldParentPtr("list_node", current);
            self._current = current.next;
            return .{
                .name = file.node.name(),
                .kind = file.node.filetype(),
            };
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
