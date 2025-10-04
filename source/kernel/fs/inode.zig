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

pub const Node = union(enum) {
    pub const Self = @This();
    file: kernel.fs.IFile,
    directory: kernel.fs.IDirectory,

    pub fn create_file(file: *kernel.fs.IFile) Node {
        return .{
            .file = file,
        };
    }

    pub fn create_directory(directory: *kernel.fs.IDirectory) Node {
        return .{
            .directory = directory,
        };
    }

    pub fn is_file(self: *const Self) bool {
        return switch (self) {
            .file => true,
            .directory => false,
        };
    }

    pub fn is_directory(self: *const Self) bool {
        return switch (self) {
            .file => false,
            .directory => true,
        };
    }

    pub fn as_file(self: *Self) ?*kernel.fs.IFile {
        return switch (self) {
            .file => &self.file,
            .directory => null,
        };
    }

    pub fn as_directory(self: *Self) ?*kernel.fs.IDirectory {
        return switch (self) {
            .file => null,
            .directory => &self.directory,
        };
    }

    pub fn delete(self: *Self) void {
        switch (self) {
            .file => self.file.interface.delete(),
            .directory => self.directory.interface.delete(),
        }
    }
};
