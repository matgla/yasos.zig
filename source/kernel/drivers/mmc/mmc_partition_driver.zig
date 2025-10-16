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

const IDriver = @import("../idriver.zig").IDriver;
const IFile = @import("../../fs/fs.zig").IFile;
const MmcPartitionFile = @import("mmc_partition_file.zig").MmcPartitionFile;

const interface = @import("interface");

const hal = @import("hal");
const kernel = @import("../../kernel.zig");

const log = std.log.scoped(.@"mmc/driver");

pub const MmcPartitionDriver = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();
    _name: []const u8,
    _start_lba: u32,
    _size_in_sectors: u32,
    _node: kernel.fs.Node,
    var refcounter: i16 = 0;

    pub fn create(allocator: std.mem.Allocator, dev: kernel.fs.IFile, driver_name: []const u8, start_lba: u32, size_in_sectors: u32) !MmcPartitionDriver {
        refcounter += 1;
        return MmcPartitionDriver.init(.{
            ._name = driver_name,
            ._start_lba = start_lba,
            ._size_in_sectors = size_in_sectors,
            ._node = try MmcPartitionFile.InstanceType.create_node(allocator, dev, driver_name, start_lba, size_in_sectors),
        });
    }

    pub fn __clone(self: *Self, other: *const Self) void {
        self.* = other.*;
        refcounter += 1;
        @panic("Clone called");
        // return self.*;
    }

    pub fn delete(self: *Self) void {
        refcounter -= 1;
        if (refcounter > 0) {
            return;
        }
        self._node.delete();
    }

    pub fn node(self: *Self) anyerror!kernel.fs.Node {
        return try self._node.clone();
    }

    pub fn load(self: *Self) anyerror!void {
        _ = self;
    }

    pub fn unload(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }
});
