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
    _node: kernel.fs.Node,
    _refcounter: *i16,
    var global_refcount: i16 = 0;

    pub fn create(allocator: std.mem.Allocator, mmc: *hal.mmc.Mmc, driver_name: []const u8) !MmcDriver {
        const mmcio = try allocator.create(MmcIo);
        mmcio.* = MmcIo.create(mmc);
        const refcounter = try allocator.create(i16);
        refcounter.* = 1;
        global_refcount += 1;
        return MmcDriver.init(.{
            ._allocator = allocator,
            ._mmcio = mmcio,
            ._name = driver_name,
            ._card_type = null,
            ._size = 0,
            ._initialized = false,
            ._node = try MmcFile.InstanceType.create_node(allocator, mmcio, driver_name),
            ._refcounter = refcounter,
        });
    }

    pub fn __clone(self: *Self, other: *const Self) void {
        self.* = other.*;
        global_refcount += 1;
        self._refcounter.* += 1;
    }

    pub fn node(self: *Self) anyerror!kernel.fs.Node {
        return try self._node.clone();
    }

    pub fn load(self: *Self) anyerror!void {
        try self._mmcio.init();
    }

    pub fn unload(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn delete(self: *Self) void {
        // this cannot be removed before all copies are gone
        self._refcounter.* -= 1;
        if (self._refcounter.* > 0) {
            return;
        }

        self._allocator.destroy(self._mmcio);
        self._allocator.destroy(self._refcounter);
        self._node.delete();
        global_refcount -= 1;
        if (global_refcount == 0) {
            // self._mmcio.deinit();
        }
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }
});

test "MmcDriver.Create.ShouldInitializeCorrectly" {
    var mmc_stub = hal.mmc.Mmc.create(.{
        .mode = .SPI,
        .pins = .{
            .clk = 0,
            .cmd = 1,
            .d0 = 2,
        },
    });
    defer mmc_stub.impl.reset();

    var driver = try (try MmcDriver.InstanceType.create(std.testing.allocator, &mmc_stub, "mmc0")).interface.new(std.testing.allocator);
    defer driver.interface.delete();
    var driver2 = try (try MmcDriver.InstanceType.create(std.testing.allocator, &mmc_stub, "mmc1")).interface.new(std.testing.allocator);
    defer driver2.interface.delete();
    var driver3 = try driver2.clone();
    defer driver3.interface.delete();

    try std.testing.expectEqualStrings("mmc1", driver3.interface.name());

    try std.testing.expectEqualStrings("mmc0", driver.interface.name());
    var node = try driver.interface.node();
    defer node.delete();

    try std.testing.expectEqual(@as(u32, 0), node.as_file().?.interface.size());
    try std.testing.expectEqual(kernel.fs.FileType.BlockDevice, node.filetype());

    try std.testing.expect(!mmc_stub.impl.initialized);
    try std.testing.expect(driver2.interface.unload());
    try std.testing.expectError(error.CardInitializationFailure, driver.interface.load());
}
