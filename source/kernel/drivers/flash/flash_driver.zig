//
// uart_driver.zig
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

const IDriver = @import("../idriver.zig").IDriver;
const IFile = @import("../../fs/fs.zig").IFile;
const FlashFile = @import("flash_file.zig").FlashFile;
const interface = @import("interface");

const kernel = @import("../../kernel.zig");

const hal = @import("hal");

pub fn FlashDriver(ImplType: anytype) type {
    const Internal = struct {
        const FlashDriverImpl = interface.DeriveFromBase(IDriver, struct {
            const Self = @This();
            const FlashType = ImplType;

            _allocator: std.mem.Allocator,
            _name: []const u8,
            _node: kernel.fs.Node,

            pub fn create(allocator: std.mem.Allocator, flash: FlashType, driver_name: []const u8) !FlashDriverImpl {
                return FlashDriverImpl.init(.{
                    ._allocator = allocator,
                    ._name = driver_name,
                    ._node = try FlashFile(FlashType).InstanceType.create_node(allocator, flash, driver_name),
                });
            }

            pub fn delete(self: *Self) void {
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
    };
    return Internal.FlashDriverImpl;
}

const FlashMock = @import("tests/FlashMock.zig").FlashMock;
const MockFlash = hal.flash.Flash(FlashMock);
const TestFlashDriver = FlashDriver(MockFlash);

fn create_test_driver() !IDriver {
    const flash = MockFlash.create(0);
    return try (try TestFlashDriver.InstanceType.create(std.testing.allocator, flash, "flash0")).interface.new(std.testing.allocator);
}

test "FlashDriver.Create.ShouldInitializeCorrectly" {
    const flash = MockFlash.create(0);
    var driver = try (try TestFlashDriver.InstanceType.create(std.testing.allocator, flash, "flash_test")).interface.new(std.testing.allocator);
    defer driver.interface.delete();

    try std.testing.expectEqualStrings("flash_test", driver.interface.name());
}

test "FlashDriver.Load.ShouldSucceed" {
    var driver = try create_test_driver();
    defer driver.interface.delete();

    try driver.interface.load();
}

test "FlashDriver.Unload.ShouldReturnTrue" {
    var driver = try create_test_driver();
    defer driver.interface.delete();

    const result = driver.interface.unload();
    try std.testing.expect(result);
}

test "FlashDriver.Node.ShouldReturnClonedNode" {
    var driver = try create_test_driver();
    defer driver.interface.delete();

    var node = try driver.interface.node();
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("flash0", node.name());
    try std.testing.expectEqual(kernel.fs.FileType.BlockDevice, node.filetype());
}

test "FlashDriver.MultipleNodes.ShouldReturnIndependentNodes" {
    var driver = try create_test_driver();
    defer driver.interface.delete();

    var node1 = try driver.interface.node();
    defer node1.delete();

    var node2 = try driver.interface.node();
    defer node2.delete();

    // Both nodes should be valid and independent
    try std.testing.expect(node1.is_file());
    try std.testing.expect(node2.is_file());
    try std.testing.expectEqualStrings("flash0", node1.name());
    try std.testing.expectEqualStrings("flash0", node2.name());
}

test "FlashDriver.LoadUnload.ShouldHandleMultipleCalls" {
    var driver = try create_test_driver();
    defer driver.interface.delete();

    // Load multiple times
    try driver.interface.load();
    try driver.interface.load();

    // Unload multiple times
    try std.testing.expect(driver.interface.unload());
    try std.testing.expect(driver.interface.unload());
}

test "FlashDriver.NodeAccess.ShouldProvideFlashFileInterface" {
    var driver = try create_test_driver();
    defer driver.interface.delete();

    var node = try driver.interface.node();
    defer node.delete();

    const maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |file| {
        // Should be a block device with proper size
        try std.testing.expectEqual(kernel.fs.FileType.BlockDevice, file.interface.filetype());
        try std.testing.expectEqual(@as(usize, 4096), file.interface.size());
    }
}
