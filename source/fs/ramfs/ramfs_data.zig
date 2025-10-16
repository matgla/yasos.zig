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

pub const RamFsDataError = error{
    FileNameTooLong,
};

pub const RamFsData = struct {
    var refcounter: i16 = 0;

    /// File contents
    _allocator: std.mem.Allocator,
    /// Buffer for filename, do not use it except of this module, instead please use: `RamFsData.name`
    name: []u8,
    data: std.ArrayListAligned(u8, .@"8"),

    pub fn create(allocator: std.mem.Allocator, filename: []const u8) !RamFsData {
        const obj = RamFsData{
            ._allocator = allocator,
            .name = try allocator.dupe(u8, filename),
            .data = try std.ArrayListAligned(u8, .@"8").initCapacity(allocator, 0),
        };
        return obj;
    }

    pub fn clone(self: *const RamFsData) RamFsData {
        refcounter += 1;
        return RamFsData{
            ._allocator = self._allocator,
            .name = self.name,
            .data = self.data,
        };
    }

    pub fn deinit(self: *RamFsData) void {
        refcounter -= 1;
        if (refcounter == 0) {
            self.data.deinit(self._allocator);
            self._allocator.free(self.name);
        }
    }
};

test "RamFsData.ShouldCreateFile" {
    var file1 = try RamFsData.create_file(std.testing.allocator, "file1");
    defer file1.deinit();
    try std.testing.expectEqualStrings("file1", file1.name());
    // try std.testing.expectEqual(FileType.File, file1.type);

    var file2 = try RamFsData.create_file(std.testing.allocator, "file3");
    defer file2.deinit();
    try std.testing.expectEqualStrings("file3", file2.name());
    // try std.testing.expectEqual(FileType.File, file2.type);

    var dir = try RamFsData.create_directory(std.testing.allocator, "dira");
    defer dir.deinit();
    try std.testing.expectEqualStrings("dira", dir.name());
    // try std.testing.expectEqual(FileType.Directory, dir.type);
}

test "RamFsData.ShouldAppendToFile" {
    var file1 = try RamFsData.create_file(std.testing.allocator, "file1");
    try file1.data.appendSlice("This is test content");
    try std.testing.expectEqualStrings("file1", file1.name());
    // try std.testing.expectEqual(FileType.File, file1.type);
    try std.testing.expectEqualStrings("This is test content", file1.data.items);

    defer file1.deinit();
}
