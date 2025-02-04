//
// romfs.zig
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

const IFileSystem = @import("../../kernel/fs/fs.zig").IFileSystem;
const IFile = @import("../../kernel/fs/fs.zig").IFile;
const FileType = @import("../../kernel/fs/ifile.zig").FileType;

const std = @import("std");

const log = &@import("../../log/kernel_log.zig").kernel_log;

pub const RomFs = struct {
    const VTable = IFileSystem.VTable{
        .mount = mount,
        .umount = umount,
        .create = create,
        .mkdir = mkdir,
        .remove = remove,
        .name = name,
        .traverse = traverse,
        .get = get,
        .has_path = has_path,
    };

    pub fn init() !RomFs {
        return .{};
    }

    pub fn ifilesystem(self: *RomFs) IFileSystem {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    fn mount(_: *anyopaque) i32 {
        return 0;
    }

    fn umount(ctx: *anyopaque) i32 {
        const self: *RomFs = @ptrCast(@alignCast(ctx));
        self.root.deinit(self.allocator);
        return 0;
    }

    fn create(_: *anyopaque, _: []const u8, _: i32) i32 {
        return -1;
    }

    fn mkdir(_: *anyopaque, _: []const u8, _: i32) i32 {
        return -1;
    }

    fn remove(_: *anyopaque, _: []const u8) i32 {
        return -1;
    }

    fn name(_: *const anyopaque) []const u8 {
        return "romfs";
    }

    fn traverse(_: *anyopaque, _: []const u8, _: *const fn (file: *IFile) void) i32 {
        return -1;
    }

    fn get(_: *anyopaque, _: []const u8) ?IFile {
        return null;
    }

    fn has_path(_: *anyopaque, _: []const u8) bool {
        return false;
    }
};
