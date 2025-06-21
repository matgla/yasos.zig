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

const IDriver = @import("../../../kernel/drivers/idriver.zig").IDriver;

pub const RomfsDeviceFile = struct {
    const VTable = IDriver.VTable{
        .read = read,
        .write = write,
        .seek = seek,
        .close = close,
        .sync = sync,
        .tell = tell,
        .size = size,
        .name = name,
        .ioctl = ioctl,
        .fcntl = fcntl,
        .stat = stat,
        .filetype = filetype,
        .dupe = dupe,
        .destroy = _destroy,
    };

    pub fn create() RomfsDeviceFile {
        return .{};
    }

    pub fn ifile(self: *RomfsDeviceFile) IDriver.IFile {
        return IDriver.IFile{
            .ptr = @ptrCast(self),
            .vtable = &RomfsDeviceFile.VTable,
        };
    }

    fn read(ctx: *anyopaque, buf: []u8) !usize {
        _ = ctx;
        _ = buf;
        return 0; // Stub implementation
    }

    fn write(ctx: *anyopaque, buf: []const u8) !usize {
        _ = ctx;
        _ = buf;
        return 0; // Stub implementation
    }
};

pub const RomfsDeviceStub = struct {
    const VTable = IDriver.VTable{
        .load = load,
        .unload = unload,
        .ifile = ifile,
        .destroy = _destroy,
    };

    path: []const u8,
    file: ?std.fs.File,

    pub fn create(filepath: []const u8) RomfsDeviceStub {
        return .{
            .path = filepath,
            .file = null,
        };
    }

    pub fn destroy(self: *RomfsDeviceStub) void {
        if (self.file) |file| {
            file.close();
        }
    }

    pub fn idriver(self: *RomfsDeviceStub) IDriver {
        return IDriver{
            .ptr = @ptrCast(self),
            .vtable = &VTable,
        };
    }

    fn load(ctx: *anyopaque) !void {
        const self: *RomfsDeviceStub = @ptrCast(@alignCast(ctx));
        const cwd = std.fs.cwd();

        self.file = try cwd.openFile(self.path, .{ .mode = .read_only });
    }

    fn unload(ctx: *anyopaque) bool {
        _ = ctx;
        return true;
    }

    fn ifile(ctx: *anyopaque) ?IDriver.IFile {
        const self: *RomfsDeviceStub = @ptrCast(@alignCast(ctx));

        return null;
    }

    fn _destroy(ctx: *anyopaque) void {
        _ = ctx;
    }
};
