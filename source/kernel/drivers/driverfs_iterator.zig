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

// test "DriverFsIterator.IterateThroughElements" {
//     const DriverMock = @import("tests/driver_mock.zig").DriverMock;
//    const FileMock = @import("../fs/tests/file_mock.zig").FileMock;
//     var file_mock = try FileMock.create(std.testing.allocator);
//     defer file_mock.delete();

//     var file0 = file_mock.get_interface();
//     defer file0.interface.delete();

//     var mapping = std.StringHashMap(kernel.driver.IDriver).init(std.testing.allocator);
//     defer mapping.deinit();

//     var driver0 = DriverStub.InstanceType.init(file0.*);
//     // defer driver0.interface.delete();
//     try mapping.put("file0", driver0.interface.create());
// }
