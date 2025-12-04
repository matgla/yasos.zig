//
// ramfs_file.zig
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

///! This module provides file handler implementation for ramfs filesystem
const std = @import("std");
const c = @import("libc_imports").c;

const kernel = @import("kernel");
const IFile = kernel.fs.IFile;
const FileName = kernel.fs.FileName;
const FileType = kernel.fs.FileType;
const IoctlCommonCommands = kernel.fs.IoctlCommonCommands;
const FileMemoryMapAttributes = kernel.fs.FileMemoryMapAttributes;

const RamFsData = @import("ramfs_data.zig").RamFsData;

const log = kernel.log;
const interface = @import("interface");

pub const RamFsFile = interface.DeriveFromBase(IFile, struct {
    const Self = @This();
    _data: *RamFsData,
    _allocator: std.mem.Allocator,

    /// Current position in file
    _position: isize,
    _name: []const u8,

    pub fn create(allocator: std.mem.Allocator, data: *RamFsData, filename: []const u8) RamFsFile {
        return RamFsFile.init(.{
            ._data = data,
            ._allocator = allocator,
            ._position = 0,
            ._name = filename,
        });
    }

    pub fn __clone(self: *Self, other: *Self) void {
        self._data = other._data.share();
        self._allocator = other._allocator;
        self._position = 0;
        self._name = other._name;
    }

    pub fn create_node(allocator: std.mem.Allocator, data: *RamFsData, filename: []const u8) anyerror!kernel.fs.Node {
        const file = try create(allocator, data, filename).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        if (self._position >= self._data.data.items.len) {
            return 0;
        }
        const length = @min(@as(isize, @intCast(self._data.data.items.len)) - self._position, @as(isize, @intCast(buffer.len)));
        @memcpy(buffer[0..@as(usize, @intCast(length))], self._data.data.items[@as(usize, @intCast(self._position))..@as(usize, @intCast(self._position + length))]);
        self._position += length;
        return @intCast(length);
    }

    pub fn write(self: *Self, data: []const u8) isize {
        if (@as(isize, @intCast(self._data.data.items.len)) < @as(isize, @intCast(data.len)) + self._position) {
            self._data.data.resize(self._allocator, @as(usize, @intCast(self._position)) + data.len) catch {
                return 0;
            };
        }
        self._data.data.replaceRange(self._allocator, @as(usize, @intCast(self._position)), data.len, data) catch {
            return 0;
        };
        self._position += @as(isize, @intCast(data.len));
        return @intCast(data.len);
    }

    pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
        switch (whence) {
            c.SEEK_SET => {
                if (offset < 0) {
                    return kernel.errno.ErrnoSet.InvalidArgument;
                }
                self._position = @intCast(offset);
            },
            c.SEEK_END => {
                const new_position: i64 = @as(i64, @intCast(self._data.data.items.len)) + offset;
                if (new_position < 0) {
                    return kernel.errno.ErrnoSet.InvalidArgument;
                }
                self._position = @as(isize, @intCast(new_position));
            },
            c.SEEK_CUR => {
                const new_position = @as(i64, @intCast(self._position)) + offset;
                if (new_position < 0) {
                    return kernel.errno.ErrnoSet.InvalidArgument;
                }

                self._position = @intCast(new_position);
            },
            else => return kernel.errno.ErrnoSet.InvalidArgument,
        }
        const outside_of_buffer = @as(i64, @intCast(self._position)) - @as(i64, @intCast(self._data.data.items.len));
        if (outside_of_buffer > 0) {
            _ = self._data.data.appendNTimes(self._allocator, ' ', @as(usize, @intCast(outside_of_buffer))) catch {
                // set errno
                return kernel.errno.ErrnoSet.OutOfMemory;
            };
        }

        return @intCast(self._position);
    }

    pub fn dupe(self: *Self) ?IFile {
        const new_file = self._allocator.create(Self) catch return null;
        new_file.* = self.*;
        return new_file.ifile();
    }

    pub fn sync(self: *Self) i32 {
        _ = self;
        // always in sync
        return 0;
    }

    pub fn tell(self: *Self) i64 {
        return @intCast(self._position);
    }

    pub fn size(self: *const Self) u64 {
        return @intCast(@sizeOf(RamFsData) + self._data.data.items.len);
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        switch (cmd) {
            @intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus) => {
                if (data == null) {
                    return -1;
                }
                var attr: *FileMemoryMapAttributes = @ptrCast(@alignCast(data.?));
                attr.is_memory_mapped = true;
                attr.mapped_address_r = self._data.data.items.ptr;
            },
            else => {
                return -1;
            },
        }
        return 0;
    }

    pub fn fcntl(self: *Self, _: i32, _: ?*anyopaque) i32 {
        _ = self;
        return 0;
    }

    pub fn filetype(self: *const Self) FileType {
        _ = self;
        return .File;
    }

    pub fn delete(self: *Self) void {
        if (self._data.deinit()) {
            self._allocator.destroy(self._data);
        }
    }
});

test "RamFsFile.ShouldReadAndWriteFile" {
    const data = std.testing.allocator.create(RamFsData) catch unreachable;
    data.* = try RamFsData.create(std.testing.allocator);

    var file = try RamFsFile.InstanceType.create(std.testing.allocator, data, "test_file").interface.new(std.testing.allocator);
    defer file.interface.delete();

    try std.testing.expectEqualStrings("test_file", file.interface.name());
    try std.testing.expectEqual(22, file.interface.write("Some data inside file\n"));
    try std.testing.expectEqual(4, file.interface.write("test"));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(0, file.interface.read(&buf));
    try std.testing.expectEqual(0, file.interface.seek(0, c.SEEK_SET));
    try std.testing.expectEqual(8, file.interface.read(&buf));
    try std.testing.expectEqualStrings("Some dat", &buf);

    var buf2: [4]u8 = undefined;
    try std.testing.expectEqual(4, file.interface.read(&buf2));
    try std.testing.expectEqualStrings("a in", &buf2);

    try std.testing.expectEqual(8, file.interface.read(&buf));
    try std.testing.expectEqualStrings("side fil", &buf);
    @memset(buf[0..], 0);
    try std.testing.expectEqual(6, file.interface.read(&buf));
    try std.testing.expectEqualStrings("e\ntest", buf[0..6]);
}

test "RamFsFile.ShouldSeekFile" {
    const data = std.testing.allocator.create(RamFsData) catch unreachable;
    data.* = try RamFsData.create(std.testing.allocator);
    var sut = RamFsFile.InstanceType.create(std.testing.allocator, data, "other_file");
    var file = try sut.interface.new(std.testing.allocator);
    defer file.interface.delete();
    try std.testing.expectEqual(10, try file.interface.seek(10, c.SEEK_CUR));
    try std.testing.expectEqual(22, file.interface.write("Some data inside file\n"));
    var buf: [16]u8 = undefined;
    try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.interface.seek(-40, c.SEEK_CUR));
    try std.testing.expectEqual(32, file.interface.tell());

    try std.testing.expectEqual(0, try file.interface.seek(-32, c.SEEK_CUR));
    try std.testing.expectEqual(16, file.interface.read(&buf));
    try std.testing.expectEqualStrings(" " ** 10 ++ "Some d", &buf);

    try std.testing.expectEqual(32, try file.interface.seek(0, c.SEEK_END));
    try std.testing.expectEqual(32, file.interface.tell());

    try std.testing.expectEqual(65, try file.interface.seek(33, c.SEEK_END));
    try std.testing.expectEqual(97, try file.interface.seek(32, c.SEEK_END));
    try std.testing.expectEqual(97, file.interface.tell());

    try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.interface.seek(-2, c.SEEK_SET));
    try std.testing.expectEqual(0, try file.interface.seek(0, c.SEEK_SET));
    try std.testing.expectEqual(0, file.interface.tell());
    try std.testing.expectEqual(132, try file.interface.seek(132, c.SEEK_SET));
    try std.testing.expectEqual(132, file.interface.tell());

    try std.testing.expectEqual(132 + @sizeOf(RamFsData), file.interface.size());
}
