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

const kernel = @import("../../kernel.zig");

pub const FileSystemStub = interface.DeriveFromBase(kernel.fs.IFileSystem, struct {
    const Self = @This();
    has_file: bool = true,

    pub fn mount(_: *Self) i32 {
        return 0;
    }

    pub fn umount(_: *Self) i32 {
        return 0;
    }

    pub fn create(_: *Self, _: []const u8, _: i32, _: std.mem.Allocator) ?kernel.fs.IFile {
        return null;
    }

    pub fn mkdir(_: *Self, _: []const u8, _: i32) i32 {
        return 0;
    }

    pub fn remove(_: *Self, _: []const u8) i32 {
        return 0;
    }

    pub fn name(_: *const Self) []const u8 {
        return "";
    }

    pub fn traverse(_: *Self, _: []const u8, _: *const fn (file: *kernel.fs.IFile, _: *anyopaque) bool, _: *anyopaque) i32 {
        return 0;
    }

    pub fn get(_: *Self, _: []const u8, _: std.mem.Allocator) ?kernel.fs.IFile {
        return null;
    }

    pub fn has_path(self: *const Self, _: []const u8) bool {
        return self.has_file;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }

    pub fn iterator(self: *Self, path: []const u8) ?kernel.fs.IDirectoryIterator {
        _ = self;
        _ = path;
        return null; // No directory iterator for stub
    }
});
