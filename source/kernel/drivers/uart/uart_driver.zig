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

pub fn UartDriver(comptime UartType: anytype) type {
    return struct {
        const Self = @This();
        const uart = UartType;

        const VTable = IDriver.VTable{
            .load = load,
            .unload = unload,
            .ifile = ifile,
            .destroy = _destroy,
        };

        _allocator: std.mem.Allocator,
        // object is owner of the file handle

        pub fn new(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Self {
            const object = try allocator.create(Self);
            object.* = Self.create(allocator);
            return object;
        }

        pub fn destroy(self: *Self) void {
            self._allocator.destroy(self);
        }

        pub fn create(allocator: std.mem.Allocator) Self {
            return .{
                ._allocator = allocator,
            };
        }

        pub fn idriver(self: *Self) IDriver {
            return .{
                .ptr = self,
                .vtable = &VTable,
            };
        }

        fn load(_: *anyopaque) bool {
            // uart.init(.{
            //     .baudrate = 115200,
            // }) catch {
            //     return false;
            // };
            // return true;
            return true;
        }

        fn unload(_: *anyopaque) bool {
            return true;
        }

        fn ifile(ctx: *anyopaque) ?IFile {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var file = UartFile(uart).new(self._allocator) catch {
                return null;
            };
            return file.ifile();
        }

        fn _destroy(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.destroy();
        }
    };
}
