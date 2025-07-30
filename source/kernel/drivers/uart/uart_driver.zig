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
const UartFile = @import("uart_file.zig").UartFile;

const interface = @import("interface");

pub fn UartDriver(comptime UartType: anytype) type {
    const Internal = struct {
        const UartDriverImpl = interface.DeriveFromBase(IDriver, struct {
            pub const Self = @This();
            const uart = UartType;

            pub fn create() UartDriverImpl {
                return UartDriverImpl.init(.{});
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

            pub fn ifile(self: *Self, allocator: std.mem.Allocator) ?IFile {
                _ = self;
                return (UartFile(uart).InstanceType.create(allocator)).interface.new(allocator) catch {
                    return null;
                };
            }

            pub fn delete(self: *Self) void {
                // No specific cleanup needed for UART driver
                _ = self;
            }

            pub fn name(self: *const Self) []const u8 {
                _ = self;
                return "uart";
            }
        });
    };
    return Internal.UartDriverImpl;
}
