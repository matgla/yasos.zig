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

pub const INode = interface.ConstructInterface(struct {
    const Self = @This();

    pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
        return interface.VirtualCall(self, "name", .{allocator}, kernel.fs.FileName);
    }

    pub fn filetype(self: *Self) kernel.fs.FileType {
        return interface.VirtualCall(self, "filetype", .{}, kernel.fs.FileType);
    }

    pub fn get_file(self: *Self) ?kernel.fs.IFile {
        return interface.VirtualCall(self, "get_file", .{}, ?kernel.fs.IFile);
    }

    pub fn get_directory(self: *Self) ?kernel.fs.IDirectory {
        return interface.VirtualCall(self, "get_directory", .{}, ?kernel.fs.IDirectory);
    }

    pub fn delete(self: *Self) void {
        interface.DestructorCall(self);
    }
});
