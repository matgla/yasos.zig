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

const RomFsFile = @import("romfs_file.zig").RomFsFile;

const FileSystemHeader = @import("file_system_header.zig").FileSystemHeader;

const std = @import("std");

const log = &@import("../../log/kernel_log.zig").kernel_log;

pub const RomFs = struct {
    root: FileSystemHeader,
    allocator: std.mem.Allocator,

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

    pub fn init(allocator: std.mem.Allocator, memory: []const u8) ?RomFs {
        const fs = FileSystemHeader.init(memory);
        if (fs) |root| {
            return .{
                .root = root,
                .allocator = allocator,
            };
        }
        return null;
    }

    pub fn ifilesystem(self: *RomFs) IFileSystem {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    fn mount(_: *anyopaque) i32 {
        // nothing to do
        return 0;
    }

    fn umount(_: *anyopaque) i32 {
        // nothing to do
        return 0;
    }

    fn create(_: *anyopaque, _: []const u8, _: i32) i32 {
        // read-only filesystem
        return -1;
    }

    fn mkdir(_: *anyopaque, _: []const u8, _: i32) i32 {
        // read-only filesystem
        return -1;
    }

    fn remove(_: *anyopaque, _: []const u8) i32 {
        // read-only filesystem
        return -1;
    }

    fn name(_: *const anyopaque) []const u8 {
        return "romfs";
    }

    fn traverse(_: *anyopaque, _: []const u8, _: *const fn (file: *IFile) void) i32 {
        return -1;
    }

    fn get(ctx: *anyopaque, path: []const u8) ?IFile {
        const self: *RomFs = @ptrCast(@alignCast(ctx));
        var it = try std.fs.path.componentIterator(path);
        var component = it.first();
        var node = self.root.first_file_header();
        while (component) |part| : (component = it.next()) {
            while (!std.mem.eql(u8, node.name(), part.name)) {
                const maybe_node = node.next();
                if (maybe_node == null) {
                    return null;
                }
                node = maybe_node.?;
            }
            // TODO: symbolic link support
            if (node.filetype() != FileType.Directory) {
                return null;
            }
        }

        // return file
        const file = self.allocator.create(RomFsFile) catch return null;
        file.* = RomFsFile.init(self.allocator, node);
        return file.ifile();
    }

    fn has_path(_: *anyopaque, _: []const u8) bool {
        return false;
    }
};

test "Parsing filesystem" {
    const test_data = @embedFile("test.romfs");
    var maybe_fs = RomFs.init(std.testing.allocator, test_data);
    if (maybe_fs) |*fs| {
        const ifs = fs.ifilesystem();
        const maybe_root_directory = ifs.get("/");
        try std.testing.expect(maybe_root_directory != null);
        if (maybe_root_directory) |root_directory| {
            defer _ = root_directory.close();
            try std.testing.expectEqualStrings(root_directory.name(), ".");
        }
    }
}
