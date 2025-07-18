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
const interface = @import("interface");

const hal = @import("hal");
const board = @import("board");

pub const FlashDriver = struct {
    pub usingnamespace interface.DeriveFromBase(IDriver, FlashDriver);
    const FlashType = @TypeOf(board.flash.flash0);

    _flash: FlashType,

    pub fn create(flash: FlashType) FlashDriver {
        return .{
            ._flash = flash,
        };
    }

    pub fn ifile(self: *FlashDriver, allocator: std.mem.Allocator) ?IFile {
        const file = FlashFile(FlashType).create(allocator, &self._flash).new(allocator) catch {
            return null;
        };
        return file;
    }

    pub fn load(self: *FlashDriver) anyerror!void {
        try self._flash.init();
    }

    pub fn unload(self: *FlashDriver) bool {
        _ = self;
        return true;
    }

    pub fn delete(self: *FlashDriver) void {
        _ = self;
    }

    pub fn name(self: *const FlashDriver) []const u8 {
        _ = self;
        return "flash";
    }
};
