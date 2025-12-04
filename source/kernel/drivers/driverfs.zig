//
// devicefs.zig
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

const ReadOnlyFileSystem = @import("../fs/ifilesystem.zig").ReadOnlyFileSystem;
const IDirectoryIterator = @import("../fs/idirectory.zig").IDirectoryIterator;
const IFile = @import("../fs/ifile.zig").IFile;

const IDriver = @import("idriver.zig").IDriver;

const interface = @import("interface");

const kernel = @import("../kernel.zig");
const c = @import("libc_imports").c;

const log = std.log.scoped(.@"vfs/driverfs");

const DriverDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    base: kernel.fs.ReadOnlyFile,
    _allocator: std.mem.Allocator,
    _container: std.StringHashMap(IDriver),
    _refcount: *i16,

    pub fn init(allocator: std.mem.Allocator) !DriverDirectory {
        const refcount: *i16 = try allocator.create(i16);
        refcount.* = 1;
        return DriverDirectory.init(.{
            .base = kernel.fs.ReadOnlyFile.init(.{}),
            ._allocator = allocator,
            ._container = std.StringHashMap(IDriver).init(allocator),
            ._refcount = refcount,
        });
    }

    pub fn __clone(self: *Self, other: *const Self) void {
        self.* = other.*;
        self._refcount.* += 1;
    }

    pub fn delete(self: *Self) void {
        self._refcount.* -= 1;
        if (self._refcount.* > 0) {
            return;
        }
        var it = self._container.iterator();

        while (it.next()) |driver| {
            log.debug("removing driver: {s}", .{driver.value_ptr.interface.name()});
            driver.value_ptr.interface.delete();
        }
        self._container.deinit();
        self._allocator.destroy(self._refcount);
    }

    pub fn append(self: *Self, driver: IDriver, node_name: []const u8) !void {
        log.debug("mapping driver '{s}' to '{s}' ", .{ driver.interface.name(), node_name });
        self._container.put(node_name, driver) catch |err| {
            log.err("adding driver {s} failed with an error: {s}", .{ driver.interface.name(), @errorName(err) });
            return err;
        };
    }

    pub fn load_all(self: *Self) !void {
        log.debug("loading all drivers", .{});
        var it = self._container.iterator();
        while (it.next()) |driver| {
            driver.value_ptr.interface.load() catch |err| {
                log.err("Loading driver {s} failed with an error: {s}", .{ driver.value_ptr.interface.name(), @errorName(err) });
            };
        }
    }

    pub fn get(self: *Self, path: []const u8, result: *kernel.fs.Node) anyerror!void {
        if (self._container.getPtr(path)) |driver| {
            result.* = try driver.interface.node();
            return;
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "dev";
    }

    pub fn iterator(self: *const Self) anyerror!IDirectoryIterator {
        return try (kernel.driver.DriverFsIterator.InstanceType.create(self._container.iterator(), self._allocator)).interface.new(self._allocator);
    }
});

pub const DriverFs = interface.DeriveFromBase(ReadOnlyFileSystem, struct {
    const Self = @This();
    base: ReadOnlyFileSystem,
    _allocator: std.mem.Allocator,
    _root: kernel.fs.IDirectory,

    fn get_root_directory(self: *Self) *DriverDirectory.InstanceType {
        return self._root.as(DriverDirectory.InstanceType);
    }

    pub fn init(allocator: std.mem.Allocator) !DriverFs {
        log.info("created", .{});
        return DriverFs.init(.{
            .base = ReadOnlyFileSystem.init(.{}),
            ._allocator = allocator,
            ._root = try (try DriverDirectory.InstanceType.init(allocator)).interface.new(allocator),
        });
    }

    pub fn delete(self: *Self) void {
        self._root.interface.delete();
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "dev";
    }

    pub fn append(self: *Self, driver: IDriver, node_name: []const u8) !void {
        try self.get_root_directory().append(driver, node_name);
    }

    pub fn load_all(self: *Self) !void {
        try self.get_root_directory().load_all();
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return kernel.fs.Node.create_directory(try self._root.clone());
        }
        var result: kernel.fs.Node = undefined;
        const trimmed_path = std.mem.trim(u8, path, "/ ");
        try self.get_root_directory().get(trimmed_path, &result);
        return result;
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_links: bool) anyerror!void {
        _ = follow_links;
        var node = try self.get(path);
        defer node.delete();
        data.st_blksize = 512;
        data.st_rdev = 1;
        if (node.is_directory()) {
            data.st_mode = c.S_IFDIR;
        } else if (node.is_file()) {
            data.st_mode = c.S_IFREG;
            const size = node.as_file().?.interface.size();
            data.st_size = @truncate(size);
            data.st_blocks = @intCast((size + 511) / 512);
        }
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        _ = flags;
        var node = try self.get(path);
        defer node.delete();

        if ((mode & c.X_OK) != 0) {
            return kernel.errno.ErrnoSet.PermissionDenied;
        }

        if ((mode & c.W_OK) != 0) {
            return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
        }
    }
});

const DriverMock = @import("tests/driver_mock.zig").DriverMock;
const FileMock = @import("../fs/tests/file_mock.zig").FileMock;

// test "DriverFs.ShouldInitializeAndDeinitialize" {
//     var driverfs = try (try DriverFs.InstanceType.init(std.testing.allocator)).interface.new(std.testing.allocator);
//     defer driverfs.interface.delete();

//     try std.testing.expectEqualStrings("dev", driverfs.interface.name());
// }

// test "DriverFs.ShouldGetRootDirectory" {
//     var driverfs = try (try DriverFs.InstanceType.init(std.testing.allocator)).interface.new(std.testing.allocator);
//     defer driverfs.interface.delete();

//     var node = try driverfs.interface.get("/");
//     defer node.delete();

//     try std.testing.expect(node.is_directory());
//     try std.testing.expectEqualStrings("dev", node.as_directory().?.interface.name());
// }

// test "DriverFs.ShouldGetRootDirectoryWithEmptyPath" {
//     var driverfs = try (try DriverFs.InstanceType.init(std.testing.allocator)).interface.new(std.testing.allocator);
//     defer driverfs.interface.delete();

//     var node = try driverfs.interface.get("");
//     defer node.delete();

//     try std.testing.expect(node.is_directory());
// }

// test "DriverFs.ShouldAppendDriver" {
//     var sut = try DriverFs.InstanceType.init(std.testing.allocator);
//     var driverfs = sut.interface.create();
//     defer driverfs.interface.delete();

//     var mock_driver = try DriverMock.create(std.testing.allocator);
//     const driver_interface = mock_driver.get_interface();

//     const file_mock = try FileMock.create(std.testing.allocator);

//     _ = mock_driver
//         .expectCall("name")
//         .willReturn("test_device")
//         .times(2);

//     try sut.data().append(driver_interface, "test_device");

//     const node = kernel.fs.Node.create_file(file_mock.interface);
//     _ = mock_driver
//         .expectCall("node")
//         .willReturn(node);

//     var devnode = try driverfs.interface.get("test_device");

//     defer devnode.delete();
//     try std.testing.expect(devnode.is_file());

//     _ = file_mock
//         .expectCall("name")
//         .willReturn("yyy");
//     try std.testing.expectEqualStrings("yyy", devnode.as_file().?.interface.name());
// }

// test "DriverFs.ShouldReturnErrorForNonExistentDriver" {
//     var sut = try (try DriverFs.InstanceType.init(std.testing.allocator)).interface.new(std.testing.allocator);
//     defer sut.interface.delete();

//     try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.interface.get("nonexistent"));
// }

// test "DriverFs.ShouldLoadAllDrivers" {
//     var sut = try DriverFs.InstanceType.init(std.testing.allocator);
//     var driverfs = try sut.interface.new(std.testing.allocator);
//     defer driverfs.interface.delete();

//     var mock_driver1 = try DriverMock.create(std.testing.allocator);
//     defer mock_driver1.delete();
//     var mock_driver2 = try DriverMock.create(std.testing.allocator);
//     defer mock_driver2.delete();
//     var mock_driver3 = try DriverMock.create(std.testing.allocator);
//     defer mock_driver3.delete();

//     _ = mock_driver1
//         .expectCall("name")
//         .willReturn("driver1")
//         .times(2);

//     _ = mock_driver2
//         .expectCall("name")
//         .willReturn("driver2")
//         .times(3);

//     _ = mock_driver3
//         .expectCall("name")
//         .willReturn("driver3")
//         .times(2);

//     try sut.data().append(mock_driver1.get_interface(), "device1");
//     try sut.data().append(mock_driver2.get_interface(), "device2");
//     try sut.data().append(mock_driver3.get_interface(), "device3");

//     _ = mock_driver1
//         .expectCall("load")
//         .times(1);

//     _ = mock_driver2
//         .expectCall("load")
//         .times(1)
//         .willReturn(kernel.errno.ErrnoSet.FileTooLarge);

//     _ = mock_driver3
//         .expectCall("load")
//         .times(1);

//     try sut.data().load_all();
// }

// test "DriverFs.ShouldStatRootDirectory" {
//     var driverfs = try (try DriverFs.InstanceType.init(std.testing.allocator)).interface.new(std.testing.allocator);
//     defer driverfs.interface.delete();

//     var stat_buf: c.struct_stat = undefined;
//     try driverfs.interface.stat("/", &stat_buf, true);

//     try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
// }

// test "DriverFs.ShouldStatDevice" {
//     var sut = try DriverFs.InstanceType.init(std.testing.allocator);
//     var driverfs = sut.interface.create();
//     defer driverfs.interface.delete();

//     var mock_driver = try DriverMock.create(std.testing.allocator);
//     const driver_interface = mock_driver.get_interface();

//     const file_mock = try FileMock.create(std.testing.allocator);

//     _ = mock_driver
//         .expectCall("name")
//         .willReturn("test_device")
//         .times(2);

//     try sut.data().append(driver_interface, "test_device");

//     const node = kernel.fs.Node.create_file(file_mock.interface);

//     _ = mock_driver
//         .expectCall("node")
//         .willReturn(node);

//     var stat_buf: c.struct_stat = undefined;
//     try driverfs.interface.stat("/test_device", &stat_buf, true);
//     try std.testing.expectEqual(@as(c_uint, c.S_IFREG), stat_buf.st_mode);
// }

// test "DriverFs.ShouldIterateDrivers" {
//     var sut = try DriverFs.InstanceType.init(std.testing.allocator);
//     var driverfs = sut.interface.create();
//     defer driverfs.interface.delete();

//     var mock_driver1 = try DriverMock.create(std.testing.allocator);
//     defer mock_driver1.delete();
//     var mock_driver2 = try DriverMock.create(std.testing.allocator);
//     defer mock_driver2.delete();

//     _ = mock_driver1
//         .expectCall("name")
//         .willReturn("driver1")
//         .times(2);

//     _ = mock_driver2
//         .expectCall("name")
//         .willReturn("driver2")
//         .times(2);

//     try sut.data().append(mock_driver1.get_interface(), "device1");
//     try sut.data().append(mock_driver2.get_interface(), "device2");

//     var root = try driverfs.interface.get("/");
//     defer root.delete();

//     var maybe_dir = root.as_directory();
//     try std.testing.expect(maybe_dir != null);

//     if (maybe_dir) |*dir| {
//         var iterator = try dir.interface.iterator();
//         defer iterator.interface.delete();

//         var count: usize = 0;
//         var found_device1 = false;
//         var found_device2 = false;

//         while (iterator.interface.next()) |entry| {
//             count += 1;
//             if (std.mem.eql(u8, entry.name, "device1")) {
//                 found_device1 = true;
//             }
//             if (std.mem.eql(u8, entry.name, "device2")) {
//                 found_device2 = true;
//             }
//         }

//         try std.testing.expectEqual(@as(usize, 2), count);
//         try std.testing.expect(found_device1);
//         try std.testing.expect(found_device2);
//     }
// }

// test "DriverFs.ShouldHandleAccessPermissions" {
//     var sut = try DriverFs.InstanceType.init(std.testing.allocator);
//     var driverfs = try sut.interface.new(std.testing.allocator);
//     defer driverfs.interface.delete();

//     var mock_driver = try DriverMock.create(std.testing.allocator);
//     defer mock_driver.delete();

//     const file_mock = try FileMock.create(std.testing.allocator);
//     const node = kernel.fs.Node.create_file(file_mock.interface);

//     _ = mock_driver
//         .expectCall("name")
//         .willReturn("test_device")
//         .times(interface.mock.any{});

//     _ = mock_driver
//         .expectCall("node")
//         .willReturn(node)
//         .times(interface.mock.any{});

//     try sut.data().append(mock_driver.get_interface(), "test_device");

//     // Should reject write access
//     try std.testing.expectError(kernel.errno.ErrnoSet.ReadOnlyFileSystem, driverfs.interface.access("test_device", c.W_OK, 0));

//     // Should reject execute access
//     try std.testing.expectError(kernel.errno.ErrnoSet.PermissionDenied, driverfs.interface.access("test_device", c.X_OK, 0));

//     // Should allow read access
//     try driverfs.interface.access("test_device", c.R_OK, 0);

//     // Should allow file existence check
//     try driverfs.interface.access("test_device", c.F_OK, 0);

//     // Should reject access to non-existent device
//     try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, driverfs.interface.access("nonexistent", c.F_OK, 0));
// }
