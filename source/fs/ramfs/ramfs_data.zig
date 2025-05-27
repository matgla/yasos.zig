//
// ramfs_data.zig
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

///! This module provides basic file implementation for RamFS filesystem
const std = @import("std");

const config = @import("config");

const FileType = @import("../../kernel/fs/ifile.zig").FileType;

const log = &@import("../../log/kernel_log.zig").kernel_log;

pub const RamFsDataError = error{
    FileNameTooLong,
};

pub const RamFsData = struct {
    /// File type, users may use that field
    type: FileType,
    /// File contents
    data: std.ArrayListAligned(u8, .@"16"),

    /// Buffer for filename, do not use it except of this module, instead please use: `RamFsData.name`
    _name_buffer: [config.ramfs.max_filename]u8,
    pub fn create(allocator: std.mem.Allocator, filename: []const u8, filetype: FileType) !RamFsData {
        if (filename.len + 1 >= config.ramfs.max_filename) {
            return RamFsDataError.FileNameTooLong;
        }
        var obj = RamFsData{
            .type = filetype,
            .data = std.ArrayListAligned(u8, .@"16").init(allocator),
            ._name_buffer = undefined,
        };

        @memcpy(obj._name_buffer[0..filename.len], filename);
        obj._name_buffer[filename.len] = 0;
        return obj;
    }

    pub fn deinit(self: *RamFsData) void {
        self.data.deinit();
    }

    pub inline fn create_file(allocator: std.mem.Allocator, filename: []const u8) !RamFsData {
        return create(allocator, filename, FileType.File);
    }

    pub inline fn create_directory(allocator: std.mem.Allocator, filename: []const u8) !RamFsData {
        return create(allocator, filename, FileType.Directory);
    }

    pub fn name(self: *const RamFsData) []const u8 {
        return std.mem.sliceTo(&self._name_buffer, 0);
    }
};

test "create nodes" {
    var file1 = try RamFsData.create_file(std.testing.allocator, "file1");
    try std.testing.expectEqualStrings("file1", file1.name());
    try std.testing.expectEqual(FileType.File, file1.type);
    defer file1.deinit();

    var file2 = try RamFsData.create_file(std.testing.allocator, "file3");
    try std.testing.expectEqualStrings("file3", file2.name());
    try std.testing.expectEqual(FileType.File, file2.type);
    defer file2.deinit();

    var dir = try RamFsData.create_directory(std.testing.allocator, "dira");
    try std.testing.expectEqualStrings("dira", dir.name());
    try std.testing.expectEqual(FileType.Directory, dir.type);
    defer dir.deinit();
}

test "write content to file" {
    var file1 = try RamFsData.create_file(std.testing.allocator, "file1");
    try file1.data.appendSlice("This is test content");
    try std.testing.expectEqualStrings("file1", file1.name());
    try std.testing.expectEqual(FileType.File, file1.type);
    try std.testing.expectEqualStrings("This is test content", file1.data.items);

    defer file1.deinit();
}
