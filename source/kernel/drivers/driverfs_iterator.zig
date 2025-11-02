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

const kernel = @import("../kernel.zig");

const interface = @import("interface");

const IDirectoryIterator = kernel.fs.IDirectoryIterator;

pub const DriverFsIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    pub const Self = @This();
    pub const IteratorType = std.StringHashMap(kernel.driver.IDriver).Iterator;

    _iterator: IteratorType,
    _allocator: std.mem.Allocator,

    pub fn create(iterator: IteratorType, allocator: std.mem.Allocator) DriverFsIterator {
        return DriverFsIterator.init(.{
            ._iterator = iterator,
            ._allocator = allocator,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.DirectoryEntry {
        if (self._iterator.next()) |driver| {
            return .{
                .name = driver.key_ptr.*,
                .kind = .File,
            };
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

const DriverMock = @import("tests/driver_mock.zig").DriverMock;

test "DriverFsIterator.ShouldIterateEmptyHashMap" {
    var drivers = std.StringHashMap(kernel.driver.IDriver).init(std.testing.allocator);
    defer drivers.deinit();

    var iterator = try DriverFsIterator.InstanceType.create(drivers.iterator(), std.testing.allocator).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    const entry = iterator.interface.next();
    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), entry);
}

test "DriverFsIterator.ShouldIterateSingleDriver" {
    var drivers = std.StringHashMap(kernel.driver.IDriver).init(std.testing.allocator);
    defer drivers.deinit();

    var mock_driver = try DriverMock.create(std.testing.allocator);
    var mock = mock_driver.get_interface();
    defer mock.interface.delete();

    try drivers.put("device1", mock_driver.get_interface());

    var iterator = try DriverFsIterator.InstanceType.create(drivers.iterator(), std.testing.allocator).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    const entry = iterator.interface.next();
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("device1", entry.?.name);
    try std.testing.expectEqual(kernel.fs.FileType.File, entry.?.kind);

    const next_entry = iterator.interface.next();
    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), next_entry);
}

test "DriverFsIterator.ShouldIterateMultipleDrivers" {
    var drivers = std.StringHashMap(kernel.driver.IDriver).init(std.testing.allocator);
    defer drivers.deinit();

    var mock_driver1 = try DriverMock.create(std.testing.allocator);
    var mock1 = mock_driver1.get_interface();
    defer mock1.interface.delete();

    var mock_driver2 = try DriverMock.create(std.testing.allocator);
    var mock2 = mock_driver2.get_interface();
    defer mock2.interface.delete();

    var mock_driver3 = try DriverMock.create(std.testing.allocator);
    var mock3 = mock_driver3.get_interface();
    defer mock3.interface.delete();

    try drivers.put("device1", mock_driver1.get_interface());
    try drivers.put("device2", mock_driver2.get_interface());
    try drivers.put("device3", mock_driver3.get_interface());

    var iterator = try DriverFsIterator.InstanceType.create(drivers.iterator(), std.testing.allocator).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    var count: usize = 0;
    var found = std.StringHashMap(void).init(std.testing.allocator);
    defer found.deinit();

    while (iterator.interface.next()) |entry| {
        count += 1;
        try std.testing.expectEqual(kernel.fs.FileType.File, entry.kind);
        try found.put(entry.name, {});
    }

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(found.contains("device1"));
    try std.testing.expect(found.contains("device2"));
    try std.testing.expect(found.contains("device3"));
}

test "DriverFsIterator.ShouldReturnNullAfterIterationComplete" {
    var drivers = std.StringHashMap(kernel.driver.IDriver).init(std.testing.allocator);
    defer drivers.deinit();

    var mock_driver = try DriverMock.create(std.testing.allocator);
    var mock = mock_driver.get_interface();
    defer mock.interface.delete();

    try drivers.put("device1", mock_driver.get_interface());

    var iterator = try DriverFsIterator.InstanceType.create(drivers.iterator(), std.testing.allocator).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    // First call should return the entry
    const entry1 = iterator.interface.next();
    try std.testing.expect(entry1 != null);

    // Subsequent calls should return null
    const entry2 = iterator.interface.next();
    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), entry2);

    const entry3 = iterator.interface.next();
    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), entry3);
}

test "DriverFsIterator.ShouldIterateDriversWithDifferentNames" {
    var drivers = std.StringHashMap(kernel.driver.IDriver).init(std.testing.allocator);
    defer drivers.deinit();

    var mock_driver1 = try DriverMock.create(std.testing.allocator);
    var mock1 = mock_driver1.get_interface();
    defer mock1.interface.delete();

    var mock_driver2 = try DriverMock.create(std.testing.allocator);
    var mock2 = mock_driver2.get_interface();
    defer mock2.interface.delete();

    try drivers.put("uart0", mock_driver1.get_interface());
    try drivers.put("spi1", mock_driver2.get_interface());

    var iterator = try DriverFsIterator.InstanceType.create(drivers.iterator(), std.testing.allocator).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    var names = try std.ArrayList([]const u8).initCapacity(std.testing.allocator, 1);
    defer names.deinit(std.testing.allocator);

    while (iterator.interface.next()) |entry| {
        try names.append(std.testing.allocator, entry.name);
        try std.testing.expectEqual(kernel.fs.FileType.File, entry.kind);
    }

    try std.testing.expectEqual(@as(usize, 2), names.items.len);

    // Check that both names are present (order doesn't matter in hash map)
    var found_uart0 = false;
    var found_spi1 = false;
    for (names.items) |name| {
        if (std.mem.eql(u8, name, "uart0")) found_uart0 = true;
        if (std.mem.eql(u8, name, "spi1")) found_spi1 = true;
    }
    try std.testing.expect(found_uart0);
    try std.testing.expect(found_spi1);
}

test "DriverFsIterator.ShouldAlwaysReturnFileType" {
    var drivers = std.StringHashMap(kernel.driver.IDriver).init(std.testing.allocator);
    defer drivers.deinit();

    var mock_driver1 = try DriverMock.create(std.testing.allocator);
    var mock1 = mock_driver1.get_interface();
    defer mock1.interface.delete();

    var mock_driver2 = try DriverMock.create(std.testing.allocator);
    var mock2 = mock_driver2.get_interface();
    defer mock2.interface.delete();

    try drivers.put("dev1", mock_driver1.get_interface());
    try drivers.put("dev2", mock_driver2.get_interface());

    var iterator = try DriverFsIterator.InstanceType.create(drivers.iterator(), std.testing.allocator).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    while (iterator.interface.next()) |entry| {
        // All driver entries should be of type File
        try std.testing.expectEqual(kernel.fs.FileType.File, entry.kind);
    }
}

test "DriverFsIterator.ShouldHandleLongDeviceNames" {
    var drivers = std.StringHashMap(kernel.driver.IDriver).init(std.testing.allocator);
    defer drivers.deinit();

    var mock_driver = try DriverMock.create(std.testing.allocator);
    var mock = mock_driver.get_interface();
    defer mock.interface.delete();

    const long_name = "very_long_device_name_that_should_still_work_correctly";
    try drivers.put(long_name, mock_driver.get_interface());

    var iterator = try DriverFsIterator.InstanceType.create(drivers.iterator(), std.testing.allocator).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    const entry = iterator.interface.next();
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings(long_name, entry.?.name);
    try std.testing.expectEqual(kernel.fs.FileType.File, entry.?.kind);
}
