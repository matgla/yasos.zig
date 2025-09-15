//
// mmc_node.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//

const std = @import("std");
const c = @import("libc_imports").c;

const interface = @import("interface");
const hal = @import("hal");

const kernel = @import("../../kernel.zig");

const MmcPartitionFile = @import("mmc_partition_file.zig").MmcPartitionFile;

pub const MmcPartitionNode = interface.DeriveFromBase(kernel.fs.INode, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _name: []const u8,
    _dev: *kernel.fs.IFile,
    _start_lba: u32,
    _size_in_sectors: u32,
    _current_position: c.off_t,

    pub fn delete(self: *Self) void {
        _ = self;
    }

    pub fn create(allocator: std.mem.Allocator, filename: []const u8, dev: *kernel.fs.IFile, start_lba: u32, size_in_sectors: u32) MmcPartitionFile {
        return MmcPartitionNode.init(.{
            ._allocator = allocator,
            ._name = filename,
            ._dev = dev,
            ._start_lba = start_lba,
            ._size_in_sectors = size_in_sectors,
            ._current_position = @as(c.off_t, @intCast(start_lba)) << 9,
        });
    }

    pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
        _ = allocator;
        return kernel.fs.FileName.init(self._name, null);
    }

    pub fn get_file(self: *Self) ?kernel.fs.IFile {
        return (MmcPartitionFile.InstanceType.create(self._allocator, self._name, self._dev, self._start_lba, self._size_in_sectors)).interface.new(self._allocator) catch {
            return null;
        };
    }

    pub fn get_directory(self: *Self) ?kernel.fs.IDirectory {
        _ = self;
        return null;
    }

    pub fn filetype(self: *Self) kernel.fs.FileType {
        _ = self;
        return kernel.fs.FileType.BlockDevice;
    }
});
