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
const MmcFile = @import("mmc_file.zig").MmcFile;
const MmcNode = @import("mmc_node.zig").MmcNode;
const MmcIo = @import("mmc_io.zig").MmcIo;
const MmcPartitionDriver = @import("mmc_partition_driver.zig").MmcPartitionDriver;
const kernel = @import("../../kernel.zig");

const interface = @import("interface");

const hal = @import("hal");

const log = std.log.scoped(.@"mmc/driver");

const card_parser = @import("card_parser.zig");

const CardType = enum(u2) {
    MMCv3,
    SDv1,
    SDv2Block,
    SDv2Byte,
};

const R1 = struct {
    r1: u8,

    pub fn init() R1 {
        return .{
            .r1 = 0,
        };
    }
};
const R3 = struct {
    r1: u8,
    ocr: u32,

    pub fn init() R3 {
        return .{
            .r1 = 0,
            .ocr = 0,
        };
    }
};
const R7 = R3;

pub const MmcDriver = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _mmcio: *MmcIo,
    _name: []const u8,
    _card_type: ?CardType,
    _size: u32,
    _initialized: bool,
    _node: kernel.fs.INode,

    pub fn create(allocator: std.mem.Allocator, mmc: hal.mmc.Mmc, driver_name: []const u8) !MmcDriver {
        const mmcio = try allocator.create(MmcIo);
        mmcio.* = MmcIo.create(mmc);
        const mmcnode = try (try MmcNode.InstanceType.create(allocator, mmcio, driver_name)).interface.new(allocator);
        return MmcDriver.init(.{
            ._allocator = allocator,
            ._mmcio = mmcio,
            ._name = driver_name,
            ._card_type = null,
            ._size = 0,
            ._initialized = false,
            ._node = mmcnode,
        });
    }

    pub fn inode(self: *Self) ?*kernel.fs.INode {
        return &self._node;
    }

    pub fn partition_driver(self: *Self, allocator: std.mem.Allocator) ?IDriver {
        const driver = MmcPartitionDriver(Self).InstanceType.create(self, "mmc_smth").interface.new(allocator) catch return null;
        return driver;
    }

    pub fn load(self: *Self) anyerror!void {
        try self._mmcio.init();
    }

    pub fn unload(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn delete(self: *Self) void {
        self._mmcio.deinit();
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }
});
