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

const interface = @import("interface");

const kernel = @import("../kernel.zig");

pub const IDirectory = interface.ConstructCountingInterface(struct {
    const Self = @This();

    pub fn get(self: *Self, node_name: []const u8, node: *kernel.fs.Node) anyerror!void {
        return interface.CountingInterfaceVirtualCall(self, "get", .{ node_name, node }, anyerror!void);
    }

    pub fn name(self: *const Self) []const u8 {
        return interface.CountingInterfaceVirtualCall(self, "name", .{}, []const u8);
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        return interface.CountingInterfaceVirtualCall(self, "iterator", .{}, anyerror!kernel.fs.IDirectoryIterator);
    }

    pub fn delete(self: *Self) void {
        interface.CountingInterfaceDestructorCall(self);
    }
});

pub const DirectoryEntry = struct {
    name: []const u8,
    kind: kernel.fs.FileType,
};

pub const IDirectoryIterator = interface.ConstructInterface(struct {
    pub const Self = @This();

    pub fn next(self: *Self) ?DirectoryEntry {
        return interface.VirtualCall(self, "next", .{}, ?DirectoryEntry);
    }

    pub fn delete(self: *Self) void {
        interface.DestructorCall(self);
    }
});
