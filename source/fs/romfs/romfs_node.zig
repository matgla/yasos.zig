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

const FileHeader = @import("file_header.zig").FileHeader;
const RomFsFile = @import("romfs_file.zig").RomFsFile;

pub const RomFsNode = interface.DeriveFromBase(kernel.fs.INode, struct {
    _allocator: std.mem.Allocator,
    _header: FileHeader,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, header: FileHeader) RomFsNode {
        return RomFsNode.init(.{
            ._allocator = allocator,
            ._header = header,
        });
    }

    pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
        return self._header.name(allocator);
    }

    pub fn filetype(self: *Self) kernel.fs.FileType {
        return self._header.filetype();
    }

    pub fn get_file(self: *Self) ?kernel.fs.IFile {
        if (self.filetype() == .Directory) {
            return null;
        }

        return RomFsFile.InstanceType.create(self._allocator, self._header).interface.new(self._allocator) catch {
            return null;
        };
    }

    pub fn get_directory(self: *Self) ?kernel.fs.IDirectory {
        if (self.filetype() != .Directory or self.filetype() != .HardLink or self.filetype() != .SymbolicLink) {
            return null;
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
