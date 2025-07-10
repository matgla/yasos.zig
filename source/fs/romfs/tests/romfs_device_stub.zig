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

const kernel = @import("kernel");
const IDriver = kernel.driver.IDriver;
const IFile = kernel.fs.IFile;

const interface = @import("interface");

pub const RomfsDeviceFile = struct {
    pub fn create() RomfsDeviceFile {
        return .{};
    }
};

pub const RomfsDeviceStub = struct {
    pub usingnamespace interface.DeriveFromBase(IDriver, RomfsDeviceStub);
    file: ?std.fs.File,
    allocator: *const std.mem.Allocator,
    path: []const u8,

    pub fn create(allocator: *const std.mem.Allocator, path: [:0]const u8) RomfsDeviceStub {
        return .{
            .file = null,
            .allocator = allocator,
            .path = path,
        };
    }

    pub fn destroy(self: *RomfsDeviceStub) void {
        if (self.file) |file| {
            file.close();
        }
    }

    pub fn load(self: *RomfsDeviceStub) anyerror!void {
        const cwd = std.fs.cwd();
        self.file = try cwd.openFile(self.path, .{ .mode = .read_only });
    }

    pub fn unload(self: *RomfsDeviceStub) bool {
        _ = self;
        return true;
    }

    pub fn ifile(self: *RomfsDeviceStub, allocator: std.mem.Allocator) ?IFile {
        _ = self;
        _ = allocator;
        return null;
    }

    pub fn delete(self: *RomfsDeviceStub) void {
        _ = self;
    }

    pub fn name(self: *const RomfsDeviceStub) []const u8 {
        _ = self;
        return "romfs";
    }
};
