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
const FlashNode = @import("flash_node.zig").FlashNode;
const interface = @import("interface");

const kernel = @import("../../kernel.zig");

const hal = @import("hal");
const board = @import("board");

pub const FlashDriver = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();
    const FlashType = @TypeOf(board.flash.flash0);

    _allocator: std.mem.Allocator,
    _name: []const u8,
    _node: kernel.fs.Node,

    pub fn create(allocator: std.mem.Allocator, flash: FlashType, driver_name: []const u8) !FlashDriver {
        return FlashDriver.init(.{
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
