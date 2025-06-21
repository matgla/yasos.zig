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

const hal = @import("hal");

pub fn FlashDriver() type {
    return struct {
        const Self = @This();
        const FlashType = hal.Flash;

        const VTable = IDriver.VTable{
            .load = load,
            .unload = unload,
            .ifile = _ifile,
            .destroy = _destroy,
        };

        _flash: FlashType,
        _allocator: std.mem.Allocator,
        // object is owner of the file handle

        pub fn new(allocator: std.mem.Allocator, flash: FlashType) std.mem.Allocator.Error!*Self {
            const object = try allocator.create(Self);
            object.* = Self.create(allocator, flash);
            return object;
        }

        pub fn destroy(self: *Self) void {
            self._allocator.destroy(self);
        }

        pub fn create(allocator: std.mem.Allocator, flash: FlashType) Self {
            return .{
                ._flash = flash,
                ._allocator = allocator,
            };
        }

        pub fn idriver(self: *Self) IDriver {
            return .{
                .ptr = self,
                .vtable = &VTable,
            };
        }

        pub fn ifile(self: *Self) ?IFile {
            var file = FlashFile(FlashType).new(self._allocator, &self._flash) catch {
                return null;
            };
            return file.ifile();
        }

        fn load(_: *anyopaque) !void {}

        fn unload(_: *anyopaque) bool {
            return true;
        }

        fn _ifile(ctx: *anyopaque) ?IFile {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.ifile();
        }

        fn _destroy(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.destroy();
        }
    };
}
