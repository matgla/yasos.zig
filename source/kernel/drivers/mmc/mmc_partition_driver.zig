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
    _allocator: std.mem.Allocator,
    _name: []const u8,
    _start_lba: u32,
    _size_in_sectors: u32,
    _node: kernel.fs.Node,
    _refcounter: *i16,

    pub fn create(allocator: std.mem.Allocator, dev: kernel.fs.IFile, driver_name: []const u8, start_lba: u32, size_in_sectors: u32) !MmcPartitionDriver {
        const refcounter = try allocator.create(i16);
        refcounter.* = 1;
        return MmcPartitionDriver.init(.{
            ._allocator = allocator,
            ._name = driver_name,
            ._start_lba = start_lba,
            ._size_in_sectors = size_in_sectors,
            ._node = try MmcPartitionFile.InstanceType.create_node(allocator, dev, driver_name, start_lba, size_in_sectors),
            ._refcounter = refcounter,
        });
    }

    pub fn __clone(self: *Self, other: *const Self) void {
        self.* = other.*;
        self._refcounter.* += 1;
    }

    pub fn delete(self: *Self) void {
        self._refcounter.* -= 1;
        if (self._refcounter.* > 0) {
            return;
        }
        self._node.delete();
        self._allocator.destroy(self._refcounter);
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

const FileMock = @import("../../fs/tests/file_mock.zig").FileMock;

test "MmcPartitionDriver.Create.ShouldInitializeCorrectly" {
    var filemock = try FileMock.create(std.testing.allocator);
    defer filemock.interface.interface.delete();

    var driver = try (try MmcPartitionDriver.InstanceType.create(std.testing.allocator, filemock.interface, "mmc0", 0, 100)).interface.new(std.testing.allocator);
    defer driver.interface.delete();
    var driver2 = try (try MmcPartitionDriver.InstanceType.create(std.testing.allocator, filemock.interface, "mmc1", 0, 100)).interface.new(std.testing.allocator);
    defer driver2.interface.delete();
    var driver3 = try driver2.clone();
    defer driver3.interface.delete();

    try std.testing.expectEqualStrings("mmc1", driver3.interface.name());

    try std.testing.expectEqualStrings("mmc0", driver.interface.name());
    var node = try driver.interface.node();
    defer node.delete();

    try std.testing.expectEqual(@as(u32, 51200), node.as_file().?.interface.size());
    try std.testing.expectEqual(kernel.fs.FileType.BlockDevice, node.filetype());

    try std.testing.expect(driver2.interface.unload());
}
