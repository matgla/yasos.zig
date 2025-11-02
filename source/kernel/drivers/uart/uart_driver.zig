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
const UartFile = @import("uart_file.zig").UartFile;

const kernel = @import("../../kernel.zig");

const interface = @import("interface");

pub fn UartDriver(comptime UartType: anytype) type {
    const Internal = struct {
        const UartDriverImpl = interface.DeriveFromBase(IDriver, struct {
            pub const Self = @This();
            const uart = UartType;
            _allocator: std.mem.Allocator,
            _node: kernel.fs.Node,

            pub fn create(allocator: std.mem.Allocator, driver_name: []const u8) !UartDriverImpl {
                return UartDriverImpl.init(.{
                    ._allocator = allocator,
                    ._node = try UartFile(uart).InstanceType.create_node(allocator, driver_name),
                });
            }

            pub fn delete(self: *Self) void {
                self._node.delete();
            }

            pub fn load(self: *Self) anyerror!void {
                _ = self;
                uart.flush();
                uart.init(.{
                    .baudrate = 921600,
                }) catch |err| {
                    return err;
                };
            }

            pub fn unload(self: *Self) bool {
                _ = self;
                return true;
            }

            pub fn node(self: *Self) anyerror!kernel.fs.Node {
                return try self._node.clone();
            }

            pub fn name(self: *const Self) []const u8 {
                return self._node.name();
            }
        });
    };
    return Internal.UartDriverImpl;
}

test "UartDriver.ShouldCreateAndDeleteDriver" {
    const UartMock = @import("tests/uart_mock.zig").MockUart;
    defer UartMock.reset();

    var driver = try (try UartDriver(UartMock).InstanceType.create(std.testing.allocator, "uart0")).interface.new(std.testing.allocator);
    defer driver.interface.delete();

    try driver.interface.load();
    try std.testing.expect(driver.interface.unload());
    try std.testing.expectEqualStrings("uart0", driver.interface.name());

    var node = try driver.interface.node();
    defer node.delete();
    try std.testing.expectEqualStrings("uart0", node.name());
    try std.testing.expectEqual(kernel.fs.FileType.CharDevice, node.filetype());

    try std.testing.expectEqual(UartMock.baudrate, 921600);
}
