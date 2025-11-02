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

var inode_counter: u32 = 1;

pub const RamFsData = struct {
    /// File contents
    _allocator: std.mem.Allocator,
    /// Buffer for filename, do not use it except of this module, instead please use: `RamFsData.name`
    // name: []u8,
    data: std.ArrayListAligned(u8, .@"8"),
    refcounter: *i16,
    inode: u32,

    pub fn create(allocator: std.mem.Allocator) !RamFsData {
        const obj = RamFsData{
            ._allocator = allocator,
            .data = try std.ArrayListAligned(u8, .@"8").initCapacity(allocator, 0),
            .refcounter = try allocator.create(i16),
            .inode = inode_counter,
        };
        obj.refcounter.* = 1;
        return obj;
    }

    pub fn share(self: *RamFsData) *RamFsData {
        self.refcounter.* += 1;
        return self;
    }

    pub fn deinit(self: *RamFsData) bool {
        self.refcounter.* -= 1;
        if (self.refcounter.* == 0) {
            self.data.deinit(self._allocator);
            self._allocator.destroy(self.refcounter);
            return true;
        }
        return false;
    }
};

test "RamFsData.ShouldAppendToFile" {
    var file1 = try RamFsData.create(std.testing.allocator);
    try file1.data.appendSlice(file1._allocator, "This is test content");
    try std.testing.expectEqualStrings("This is test content", file1.data.items);

    var file2 = file1.share();
    try std.testing.expect(!file1.deinit());

    try std.testing.expectEqual(file1.refcounter.*, 1);
    try std.testing.expectEqualStrings("This is test content", file2.data.items);
    try std.testing.expect(file2.deinit());
}
