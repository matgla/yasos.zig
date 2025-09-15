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
const fatfs = @import("zfat");

const kernel = @import("kernel");

const FatFsFile = @import("fatfs_file.zig").FatFsFile;
const FatFsDirectory = @import("fatfs_directory.zig").FatFsDirectory;

pub const FatFsNode = interface.DeriveFromBase(kernel.fs.INode, struct {
    _allocator: std.mem.Allocator,
    _path: [:0]const u8,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, path: [:0]const u8) FatFsNode {
        return FatFsNode.init(.{
            ._allocator = allocator,
            ._path = path,
        });
    }

    pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
        const s = fatfs.stat(self._path) catch return kernel.fs.FileName.init("", null);
        const s_dup = allocator.dupe(u8, s.name()) catch return kernel.fs.FileName.init("", null);
        return kernel.fs.FileName.init(s_dup, allocator);
    }

    pub fn filetype(self: *Self) kernel.fs.FileType {
        const s = fatfs.stat(self._path) catch return kernel.fs.FileType.Unknown;
        if (s.kind == .Directory) {
            return kernel.fs.FileType.Directory;
        }
        return kernel.fs.FileType.File;
    }

    pub fn get_file(self: *Self) ?kernel.fs.IFile {
        if (self.filetype() != .File) {
            return null;
        }
        return (FatFsFile.InstanceType.create(self._allocator, self._path) catch {
            return null;
        }).interface.new(self._allocator) catch {
            return null;
        };
    }

    pub fn get_directory(self: *Self) ?kernel.fs.IDirectory {
        if (self.filetype() != .Directory) {
            return null;
        }
        return (FatFsDirectory.InstanceType.create(self._allocator, self._path) catch {
            return null;
        }).interface.new(self._allocator) catch {
            return null;
        };
    }

    pub fn delete(self: *Self) void {
        self._allocator.free(self._path);
    }
});
