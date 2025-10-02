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

pub const IDirectory = interface.ConstructInterface(struct {
    const Self = @This();

    pub fn get(self: *Self, name: []const u8) ?*kernel.fs.INode {
        return interface.VirtualCall(self, "get", .{name}, ?*kernel.fs.INode);
    }

    pub fn close(self: *Self) void {
        interface.VirtualCall(self, "close", .{}, void);
    }

    pub fn delete(self: *Self) void {
        interface.DestructorCall(self);
    }
});

pub const IDirectoryIterator = interface.ConstructInterface(struct {
    pub const Self = @This();

    pub fn next(self: *Self) ?kernel.fs.INode {
        return interface.VirtualCall(self, "next", .{}, ?kernel.fs.INode);
    }

    pub fn delete(self: *Self) void {
        interface.DestructorCall(self);
    }
});
