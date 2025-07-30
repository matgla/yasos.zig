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

const interface = @import("interface");

const hal = @import("hal");

pub const MmcDriver = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();
    mmc: hal.mmc.Mmc,

    pub fn create(mmc: hal.mmc.Mmc) MmcDriver {
        return MmcDriver.init(.{
            .mmc = mmc,
        });
    }

    pub fn ifile(self: *Self, allocator: std.mem.Allocator) ?IFile {
        _ = self;
        _ = allocator;
        return null;
    }

    pub fn load(self: *Self) anyerror!void {
        _ = self;
    }

    pub fn unload(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "mmc";
    }
});
