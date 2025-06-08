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
const MmcFile = @import("mmc_file.zig").MmcFile;

pub fn MmcDriver(comptime MmcType: anytype) type {
    return struct {
        const Self = @This();
        const mmc = MmcType;

        const VTable = IDriver.VTable{
            .load = load,
            .unload = unload,
            .ifile = ifile,
            .destroy = _destroy,
        };

        _allocator: std.mem.Allocator,

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

        fn load(_: *anyopaque) !void {
            try mmc.init(.{
                .bus_width = 4,
                .clock_speed = 50_000_000,
                .timeout_ms = 1000,
                .use_dma = false,
            });
        }

        fn unload(_: *anyopaque) bool {
            return true;
        }

        fn ifile(ctx: *anyopaque) ?IFile {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const file = MmcFile(mmc).new(self._allocator) catch {
                return null;
            };
            return file.ifile();
        }

        fn _destroy(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self._allocator.destroy(self);
        }
    };
}
