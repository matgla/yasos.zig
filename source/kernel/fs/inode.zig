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

const log = std.log.scoped(.fs_inode);

pub const Node = struct {
    pub const Self = @This();
    const InstanceType = union(enum) {
        file: kernel.fs.IFile,
        directory: kernel.fs.IDirectory,
    };
    instance: InstanceType,

    pub fn create_file(file: kernel.fs.IFile) Node {
        return .{
            .instance = .{
                .file = file,
            },
        };
    }

    pub fn create_directory(directory: kernel.fs.IDirectory) Node {
        return .{
            .instance = .{
                .directory = directory,
            },
        };
    }

    pub fn is_file(self: Self) bool {
        return switch (self.instance) {
            .file => true,
            .directory => false,
        };
    }

    pub fn is_directory(self: Self) bool {
        return switch (self.instance) {
            .file => false,
            .directory => true,
        };
    }

    pub fn as_file(self: *Self) ?kernel.fs.IFile {
        return switch (self.instance) {
            .file => self.instance.file,
            .directory => null,
        };
    }

    pub fn as_directory(self: Self) ?kernel.fs.IDirectory {
        return switch (self.instance) {
            .file => null,
            .directory => self.instance.directory,
        };
    }

    pub fn name(self: Self) []const u8 {
        return switch (self.instance) {
            .file => self.instance.file.interface.name(),
            .directory => self.instance.directory.interface.name(),
        };
    }

    pub fn filetype(self: Self) kernel.fs.FileType {
        return switch (self.instance) {
            .file => self.instance.file.interface.filetype(),
            .directory => .Directory,
        };
    }

    pub fn delete(self: *Self) void {
        switch (self.instance) {
            .file => self.instance.file.interface.delete(),
            .directory => self.instance.directory.interface.delete(),
        }
    }

    pub fn close(self: *Self) void {
        switch (self.instance) {
            .file => self.instance.file.interface.close(),
            .directory => self.instance.directory.interface.close(),
        }
    }

    pub fn share(self: *Self) Node {
        return switch (self.instance) {
            .file => Node.create_file(self.instance.file.share()),
            .directory => Node.create_directory(self.instance.directory.share()),
        };
    }

    pub fn clone(self: *const Self) !Node {
        return switch (self.instance) {
            .file => Node.create_file(try self.instance.file.clone()),
            .directory => Node.create_directory(try self.instance.directory.clone()),
        };
    }

    pub fn sync(self: *Self) anyerror!void {
        switch (self.instance) {
            .file => _ = self.instance.file.interface.sync(),
            .directory => {},
        }
    }
};
