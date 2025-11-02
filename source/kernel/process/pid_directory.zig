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

const kernel = @import("../kernel.zig");

const log = std.log.scoped(.@"vfs/procfs/pid_directory");

const PidStatFile = @import("pidstat_file.zig").PidStatFile;

const PidIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    pub const Self = @This();
    _index: usize,
    _items: []const []const u8,

    pub fn create() PidIterator {
        return PidIterator.init(.{
            ._index = 0,
            ._items = &.{
                "stat",
                "status",
            },
        });
    }

    pub fn next(self: *Self) ?kernel.fs.DirectoryEntry {
        if (self._index >= self._items.len) {
            return null;
        }
        const entry = kernel.fs.DirectoryEntry{
            .name = self._items[self._index],
            .kind = kernel.fs.FileType.File,
        };
        self._index += 1;
        return entry;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

pub const PidDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _name: ?[]const u8,
    _pid: i16,

    pub fn create(allocator: std.mem.Allocator, pid: i16) !PidDirectory {
        var dir = PidDirectory.init(.{
            ._allocator = allocator,
            ._name = null,
            ._pid = pid,
        });
        dir.data()._name = try std.fmt.allocPrint(allocator, "{d}", .{pid});
        return dir;
    }

    pub fn __clone(self: *Self, other: *Self) void {
        self.* = other.*;
        if (self._name) |n| {
            self._name = self._allocator.dupe(u8, n) catch null;
        }
    }

    pub fn delete(self: *Self) void {
        if (self._name) |n| {
            self._allocator.free(n);
        }
    }

    pub fn create_node(allocator: std.mem.Allocator, pid: i16) anyerror!kernel.fs.Node {
        const dir = try (try create(allocator, pid)).interface.new(allocator);
        return kernel.fs.Node.create_directory(dir);
    }

    pub fn name(self: *const Self) []const u8 {
        return if (self._name) |n| n else "unknown";
    }

    pub fn get(self: *Self, nodename: []const u8, result: *kernel.fs.Node) anyerror!void {
        if (std.mem.eql(u8, "stat", nodename)) {
            result.* = try PidStatFile.InstanceType.create_node(self._allocator, self._pid, false);
            return;
        }
        if (std.mem.eql(u8, "status", nodename)) {
            result.* = try PidStatFile.InstanceType.create_node(self._allocator, self._pid, true);
            return;
        }

        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        return PidIterator.InstanceType.create().interface.new(self._allocator);
    }
});

test "PidDirectory.ShouldCreateWithPid" {
    const pid: i16 = 123;
    var dir = try (try PidDirectory.InstanceType.create(std.testing.allocator, pid)).interface.new(std.testing.allocator);
    defer dir.interface.delete();

    try std.testing.expectEqual(pid, dir.as(PidDirectory).data()._pid);
    try std.testing.expectEqualStrings("123", dir.interface.name());
}

test "PidDirectory.ShouldCreateNode" {
    const pid: i16 = 456;
    var node = try PidDirectory.InstanceType.create_node(std.testing.allocator, pid);
    defer node.delete();

    try std.testing.expect(node.is_directory());
    try std.testing.expectEqualStrings("456", node.name());
}

test "PidDirectory.ShouldGetStatFile" {
    const pid: i16 = 789;
    var sut = try (try PidDirectory.InstanceType.create(std.testing.allocator, pid)).interface.new(std.testing.allocator);
    defer sut.interface.delete();

    var node: kernel.fs.Node = undefined;
    try sut.interface.get("stat", &node);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("stat", node.name());
}

test "PidDirectory.ShouldGetStatusFile" {
    const pid: i16 = 101;
    var sut = try (try PidDirectory.InstanceType.create(std.testing.allocator, pid)).interface.new(std.testing.allocator);
    defer sut.interface.delete();

    var node: kernel.fs.Node = undefined;
    try sut.interface.get("status", &node);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("status", node.name());
}

test "PidDirectory.ShouldReturnErrorForNonExistentFile" {
    const pid: i16 = 202;
    var sut = try (try PidDirectory.InstanceType.create(std.testing.allocator, pid)).interface.new(std.testing.allocator);
    defer sut.interface.delete();

    var node: kernel.fs.Node = undefined;
    try std.testing.expectError(error.NoEntry, sut.interface.get("nonexistent", &node));
}

test "PidDirectory.ShouldIterateFiles" {
    const pid: i16 = 303;
    var sut = try (try PidDirectory.InstanceType.create(std.testing.allocator, pid)).interface.new(std.testing.allocator);
    defer sut.interface.delete();

    var iterator = try sut.interface.iterator();
    defer iterator.interface.delete();

    var count: usize = 0;
    var found_stat = false;
    var found_status = false;

    while (iterator.interface.next()) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.name, "stat")) {
            found_stat = true;
            try std.testing.expectEqual(kernel.fs.FileType.File, entry.kind);
        }
        if (std.mem.eql(u8, entry.name, "status")) {
            found_status = true;
            try std.testing.expectEqual(kernel.fs.FileType.File, entry.kind);
        }
    }

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(found_stat);
    try std.testing.expect(found_status);
}

test "PidDirectory.ShouldHandleMultipleIterators" {
    const pid: i16 = 404;
    var sut = try (try PidDirectory.InstanceType.create(std.testing.allocator, pid)).interface.new(std.testing.allocator);
    defer sut.interface.delete();

    var iterator1 = try sut.interface.iterator();
    defer iterator1.interface.delete();

    var iterator2 = try sut.interface.iterator();
    defer iterator2.interface.delete();

    var count1: usize = 0;
    while (iterator1.interface.next()) |_| {
        count1 += 1;
    }

    var count2: usize = 0;
    while (iterator2.interface.next()) |_| {
        count2 += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count1);
    try std.testing.expectEqual(@as(usize, 2), count2);
}

test "PidDirectory.ShouldFormatPidCorrectly" {
    const test_cases = [_]struct { pid: i16, expected: []const u8 }{
        .{ .pid = 0, .expected = "0" },
        .{ .pid = 1, .expected = "1" },
        .{ .pid = 99, .expected = "99" },
        .{ .pid = 1000, .expected = "1000" },
        .{ .pid = 32767, .expected = "32767" },
    };

    for (test_cases) |tc| {
        var dir = try (try PidDirectory.InstanceType.create(std.testing.allocator, tc.pid)).interface.new(std.testing.allocator);
        defer dir.interface.delete();

        try std.testing.expectEqualStrings(tc.expected, dir.interface.name());
    }
}

test "PidDirectory.ShouldCloneDirectory" {
    const pid: i16 = 505;
    var sut = try (try PidDirectory.InstanceType.create(std.testing.allocator, pid)).interface.new(std.testing.allocator);
    defer sut.interface.delete();

    var dir2 = try sut.clone();
    defer dir2.interface.delete();

    try std.testing.expectEqualStrings("505", sut.interface.name());
    try std.testing.expectEqualStrings("505", dir2.interface.name());
}

test "PidIterator.ShouldIterateAllEntries" {
    var iterator = PidIterator.InstanceType.create();

    var entries = try std.ArrayList([]const u8).initCapacity(std.testing.allocator, 4);
    defer entries.deinit(std.testing.allocator);

    while (iterator.data().next()) |entry| {
        try entries.append(std.testing.allocator, entry.name);
        try std.testing.expectEqual(kernel.fs.FileType.File, entry.kind);
    }

    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings("stat", entries.items[0]);
    try std.testing.expectEqualStrings("status", entries.items[1]);
}

test "PidIterator.ShouldReturnNullAfterEnd" {
    var iterator = PidIterator.InstanceType.create();

    var count: usize = 0;
    while (iterator.data().next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), iterator.data().next());
    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), iterator.data().next());
}
