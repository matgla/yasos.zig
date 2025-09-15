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

const interface = @import("interface");
const fatfs = @import("zfat");

const kernel = @import("kernel");

pub const FatFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    _allocator: std.mem.Allocator,
    _path: [:0]const u8,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, path: [:0]const u8) !FatFsDirectory {
        return FatFsDirectory.init(.{
            ._allocator = allocator,
            ._path = path,
        });
    }

    pub fn delete(self: *Self) void {
        self._allocator.free(self._path);
    }
});
