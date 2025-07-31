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

const IDriver = @import("../idriver.zig").IDriver;
const kernel = @import("../../kernel.zig");

pub const DriverStub = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();
    _file: ?kernel.fs.IFile,

    pub fn init(file: ?kernel.fs.IFile) DriverStub {
        return DriverStub.init(.{
            ._file = file,
        });
    }

    pub fn load(self: *Self) anyerror!void {
        _ = self;
        return;
    }

    pub fn unload(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn ifile(self: *Self, allocator: std.mem.Allocator) ?kernel.fs.IFile {
        _ = allocator;
        return self._file;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "none";
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
