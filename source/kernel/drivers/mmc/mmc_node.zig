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

const MmcFile = @import("mmc_file.zig").MmcFile;
const MmcIo = @import("mmc_io.zig").MmcIo;

pub const MmcNode = interface.DeriveFromBase(kernel.fs.INodeBase, struct {
    const Self = @This();
    base: kernel.fs.INodeBase,
    _allocator: std.mem.Allocator,
    _name: []const u8,

    pub fn delete(self: *Self) void {
        self.base.data().delete();
    }

    pub fn create(allocator: std.mem.Allocator, io: *MmcIo, filename: []const u8) !MmcNode {
        const mmcfile = try (MmcFile.InstanceType.create(allocator, io, filename)).interface.new(allocator);
        return MmcNode.init(.{
            .base = kernel.fs.INodeBase.InstanceType.create_file(mmcfile),
            ._allocator = allocator,
            ._name = filename,
        });
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn filetype(self: *Self) kernel.fs.FileType {
        _ = self;
        return kernel.fs.FileType.BlockDevice;
    }
});
