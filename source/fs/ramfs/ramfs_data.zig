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

const c = @import("libc_imports").c;

const config = @import("config");

const kernel = @import("kernel");
const log = kernel.log;

const FileType = kernel.fs.FileType;

pub const RamFsDataError = error{
    FileNameTooLong,
};

pub const RamFsData = struct {
    /// File type, users may use that field
    type: kernel.fs.FileType,
    /// File contents
    data: std.ArrayListAligned(u8, .@"8"),
    _allocator: std.mem.Allocator,
    /// Buffer for filename, do not use it except of this module, instead please use: `RamFsData.name`
    _name_buffer: [config.ramfs.max_filename]u8,
    pub fn create(allocator: std.mem.Allocator, filename: []const u8, filetype: FileType) !RamFsData {
        if (filename.len + 1 >= config.ramfs.max_filename) {
            return RamFsDataError.FileNameTooLong;
        }
        var obj = RamFsData{
            .type = filetype,
            .data = std.ArrayListAligned(u8, .@"8").initCapacity(allocator, 0) catch return error.OutOfMemory,
            ._allocator = allocator,
            ._name_buffer = undefined,
        };

        @memcpy(obj._name_buffer[0..filename.len], filename);
        obj._name_buffer[filename.len] = 0;
        return obj;
    }

    pub fn deinit(self: *RamFsData) void {
        self.data.deinit(self._allocator);
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

    pub fn stat(self: RamFsData, buf: *c.struct_stat) void {
        buf.st_dev = 0;
        buf.st_ino = 0;
        buf.st_mode = 0;
        buf.st_nlink = 0;
        buf.st_uid = 0;
        buf.st_gid = 0;
        buf.st_rdev = 0;
        buf.st_size = @intCast(self.data.items.len);
        buf.st_blksize = 1;
        buf.st_blocks = 1;
    }
};

test "RamFsData.ShouldCreateFile" {
    var file1 = try RamFsData.create_file(std.testing.allocator, "file1");
    defer file1.deinit();
    try std.testing.expectEqualStrings("file1", file1.name());
    try std.testing.expectEqual(FileType.File, file1.type);

    var file2 = try RamFsData.create_file(std.testing.allocator, "file3");
    defer file2.deinit();
    try std.testing.expectEqualStrings("file3", file2.name());
    try std.testing.expectEqual(FileType.File, file2.type);

    var dir = try RamFsData.create_directory(std.testing.allocator, "dira");
    defer dir.deinit();
    try std.testing.expectEqualStrings("dira", dir.name());
    try std.testing.expectEqual(FileType.Directory, dir.type);
}

test "RamFsData.ShouldAppendToFile" {
    var file1 = try RamFsData.create_file(std.testing.allocator, "file1");
    try file1.data.appendSlice("This is test content");
    try std.testing.expectEqualStrings("file1", file1.name());
    try std.testing.expectEqual(FileType.File, file1.type);
    try std.testing.expectEqualStrings("This is test content", file1.data.items);

    defer file1.deinit();
}
