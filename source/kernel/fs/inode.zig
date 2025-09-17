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

pub const INode = interface.ConstructCountingInterface(struct {
    const Self = @This();

    pub fn name(self: *const Self) []const u8 {
        return interface.CountingInterfaceVirtualCall(self, "name", .{}, []const u8);
    }

    pub fn filetype(self: *Self) kernel.fs.FileType {
        return interface.CountingInterfaceVirtualCall(self, "filetype", .{}, kernel.fs.FileType);
    }

    pub fn get_file(self: *Self) ?*kernel.fs.IFile {
        return interface.CountingInterfaceVirtualCall(self, "get_file", .{}, ?*kernel.fs.IFile);
    }

    pub fn get_directory(self: *Self) ?*kernel.fs.IDirectory {
        return interface.CountingInterfaceVirtualCall(self, "get_directory", .{}, ?*kernel.fs.IDirectory);
    }

    pub fn close(self: *Self) void {
        interface.CountingInterfaceVirtualCall(self, "close", .{}, void);
    }

    pub fn delete(self: *Self) void {
        interface.CountingInterfaceDestructorCall(self);
    }
});

pub const INodeBase = interface.DeriveFromBase(INode, struct {
    pub const Self = @This();
    pub const InstanceType = union(enum) {
        file: kernel.fs.IFile,
        directory: kernel.fs.IDirectory,
    };
    _instance: InstanceType,

    pub fn create_file(file: kernel.fs.IFile) INodeBase {
        return INodeBase.init(.{ ._instance = InstanceType{ .file = file } });
    }

    pub fn create_directory(directory: kernel.fs.IDirectory) INodeBase {
        return INodeBase.init(.{ ._instance = InstanceType{ .directory = directory } });
    }

    pub fn get_file(self: *Self) ?*kernel.fs.IFile {
        switch (self._instance) {
            .file => |*file| return file,
            .directory => |_| return null,
        }
    }

    pub fn get_directory(self: *Self) ?*kernel.fs.IDirectory {
        switch (self._instance) {
            .file => |_| return null,
            .directory => |*dir| return dir,
        }
    }

    pub fn close(self: *Self) void {
        switch (self._instance) {
            .file => |*file| file.interface.close(),
            .directory => |*dir| dir.interface.close(),
        }
    }
});
