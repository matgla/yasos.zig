//
// idriver.zig
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
const IIFile = @import("../fs/ifile.zig").IFile;

pub const IDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const IFile = IIFile;

    pub const VTable = struct {
        load: *const fn (ctx: *anyopaque) anyerror!void,
        unload: *const fn (ctx: *anyopaque) bool,
        ifile: *const fn (ctx: *anyopaque) ?IFile,
        destroy: *const fn (ctx: *anyopaque) void,
    };

    pub fn load(self: IDriver) !void {
        try self.vtable.load(self.ptr);
    }

    pub fn unload(self: IDriver) bool {
        return self.vtable.unload(self.ptr);
    }

    pub fn ifile(self: IDriver) ?IFile {
        return self.vtable.ifile(self.ptr);
    }

    pub fn destroy(self: IDriver) void {
        self.vtable.destroy(self.ptr);
    }
};
