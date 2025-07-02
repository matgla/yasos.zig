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

pub const FlashDriver = struct {
    pub usingnamespace interface.DeriveFromBase(IDriver, FlashDriver);
    const FlashType = hal.Flash;

    _flash: FlashType,
    _allocator: std.mem.Allocator,

    pub fn create(flash: FlashType, allocator: std.mem.Allocator) FlashDriver {
        return .{
            ._flash = flash,
            ._allocator = allocator,
        };
    }

    pub fn ifile(self: *FlashDriver) ?IFile {
        const file = FlashFile(FlashType).create(self._allocator, &self._flash).new(self._allocator) catch {
            return null;
        };
        return file;
    }

    pub fn load(self: *FlashDriver) anyerror!void {
        _ = self;
    }

    pub fn unload(self: *FlashDriver) bool {
        _ = self;
        return true;
    }

    pub fn delete(self: *FlashDriver) void {
        _ = self;
    }
};
