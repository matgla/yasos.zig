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
// const UartNode = @import("uart_node.zig").UartNode;

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
                // const uartnode = try (try UartNode(uart).InstanceType.create(allocator, driver_name)).interface.new(allocator);

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
