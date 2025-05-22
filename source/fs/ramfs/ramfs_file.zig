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
const c = @import("../../libc_imports.zig").c;

const IFile = @import("../../kernel/fs/ifile.zig").IFile;
const FileType = @import("../../kernel/fs/ifile.zig").FileType;

const RamFsData = @import("ramfs_data.zig").RamFsData;

const IoctlCommonCommands = @import("../../kernel/fs/ifile.zig").IoctlCommonCommands;
const FileMemoryMapAttributes = @import("../../kernel/fs/ifile.zig").FileMemoryMapAttributes;

const log = &@import("../../log/kernel_log.zig").kernel_log;

pub const RamFsFile = struct {
    /// VTable for IFile interface
    const VTable = IFile.VTable{
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
        .destroy = destroy,
    };

    /// Pointer to data instance, data is kept by filesystem
    _data: *RamFsData,
    _allocator: std.mem.Allocator,

    /// Current position in file
    _position: usize = 0,

    pub fn create(data: *RamFsData, allocator: std.mem.Allocator) RamFsFile {
        return .{
            ._data = data,
            ._allocator = allocator,
        };
    }

    pub fn ifile(self: *RamFsFile) IFile {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    pub fn read(ctx: *anyopaque, buffer: []u8) isize {
        const self: *RamFsFile = @ptrCast(@alignCast(ctx));
        if (self._position >= self._data.data.items.len) {
            return 0;
        }
        const length = @min(self._data.data.items.len - self._position, buffer.len);
        @memcpy(buffer[0..length], self._data.data.items[self._position .. self._position + length]);
        self._position += length;
        return @intCast(length);
    }

    pub fn write(ctx: *anyopaque, data: []const u8) isize {
        const self: *RamFsFile = @ptrCast(@alignCast(ctx));
        if (self._data.data.items.len < data.len + self._position) {
            self._data.data.resize(self._position + data.len) catch {
                return 0;
            };
        }
        self._data.data.replaceRange(self._position, data.len, data) catch {
            return 0;
        };
        self._position += data.len;
        return @intCast(data.len);
    }

    pub fn seek(ctx: *anyopaque, offset: c.off_t, whence: i32) c.off_t {
        const self: *RamFsFile = @ptrCast(@alignCast(ctx));
        switch (whence) {
            c.SEEK_SET => {
                if (offset < 0) {
                    return -1;
                }
                self._position = @intCast(offset);
                return @intCast(self._position);
            },
            c.SEEK_END => {
                if (self._data.data.items.len >= offset) {
                    self._position = self._data.data.items.len - @as(usize, @intCast(offset));
                    return @intCast(self._position);
                } else {
                    // set errno
                    return -1;
                }
            },
            c.SEEK_CUR => {
                const new_position = @as(c.off_t, @intCast(self._position)) + offset;
                if (new_position < 0) {
                    return -1;
                }
                self._position = @intCast(new_position);
                return @intCast(self._position);
            },
            else => return -1,
        }
        return 0;
    }

    pub fn close(ctx: *anyopaque) i32 {
        const self: *RamFsFile = @ptrCast(@alignCast(ctx));
        self._allocator.destroy(self);
        return 0;
    }

    pub fn dupe(ctx: *anyopaque) ?IFile {
        const self: *RamFsFile = @ptrCast(@alignCast(ctx));
        const new_file = self._allocator.create(RamFsFile) catch return null;
        new_file.* = self.*;
        return new_file.ifile();
    }

    pub fn sync(_: *anyopaque) i32 {
        // always in sync
        return 0;
    }

    pub fn tell(ctx: *const anyopaque) c.off_t {
        const self: *const RamFsFile = @ptrCast(@alignCast(ctx));
        return @intCast(self._position);
    }

    pub fn size(ctx: *const anyopaque) isize {
        const self: *const RamFsFile = @ptrCast(@alignCast(ctx));
        return @intCast(@sizeOf(RamFsData) + self._data.data.items.len);
    }

    pub fn name(ctx: *const anyopaque) []const u8 {
        const self: *const RamFsFile = @ptrCast(@alignCast(ctx));
        return self._data.name();
    }

    pub fn ioctl(ctx: *anyopaque, cmd: i32, data: ?*anyopaque) i32 {
        const self: *const RamFsFile = @ptrCast(@alignCast(ctx));
        switch (cmd) {
            @intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus) => {
                var attr: *FileMemoryMapAttributes = @ptrCast(@alignCast(data));
                attr.is_memory_mapped = true;
                attr.mapped_address_r = self._data.data.items.ptr;
            },
            else => {
                return -1;
            },
        }
        return 0;
    }

    pub fn fcntl(_: *anyopaque, _: i32, _: ?*const anyopaque) i32 {
        return 0;
    }
    pub fn stat(ctx: *const anyopaque, buf: *c.struct_stat) void {
        const self: *const RamFsFile = @ptrCast(@alignCast(ctx));
        buf.st_dev = 0;
        buf.st_ino = 0;
        buf.st_mode = 0;
        buf.st_nlink = 0;
        buf.st_uid = 0;
        buf.st_gid = 0;
        buf.st_rdev = 0;
        buf.st_size = @intCast(self._data.data.items.len + @sizeOf(RamFsData));
        buf.st_blksize = 1;
        buf.st_blocks = 1;
    }

    pub fn filetype(ctx: *const anyopaque) FileType {
        const self: *const RamFsFile = @ptrCast(@alignCast(ctx));
        return self._data.type;
    }

    pub fn destroy(ctx: *anyopaque) void {
        const self: *RamFsFile = @ptrCast(@alignCast(ctx));
        self._allocator.destroy(self);
    }
};

test "Read and write file" {
    var data = try RamFsData.create_file(std.testing.allocator, "test_file");
    defer data.deinit();

    var sut = RamFsFile.create(&data);
    const file = sut.ifile();

    try std.testing.expectEqualStrings("test_file", file.name());
    try std.testing.expectEqual(22, file.write("Some data inside file\n"));
    try std.testing.expectEqual(4, file.write("test"));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(0, file.read(&buf));

    try std.testing.expectEqual(0, file.seek(0, c.SEEK_SET));
    try std.testing.expectEqual(8, file.read(&buf));
    try std.testing.expectEqualStrings("Some dat", &buf);

    var buf2: [4]u8 = undefined;
    try std.testing.expectEqual(4, file.read(&buf2));
    try std.testing.expectEqualStrings("a in", &buf2);

    try std.testing.expectEqual(8, file.read(&buf));
    try std.testing.expectEqualStrings("side fil", &buf);
    @memset(buf[0..], 0);
    try std.testing.expectEqual(6, file.read(&buf));
    try std.testing.expectEqualStrings("e\ntest", buf[0..6]);
}

test "Seek file" {
    var data = try RamFsData.create_file(std.testing.allocator, "test_file");
    defer data.deinit();

    var sut = RamFsFile.create(&data);
    const file = sut.ifile();
    try std.testing.expectEqual(0, file.seek(10, c.SEEK_CUR));
    try std.testing.expectEqual(22, file.write("Some data inside file\n"));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(-1, file.seek(-40, c.SEEK_CUR));
    try std.testing.expectEqual(32, file.tell());

    try std.testing.expectEqual(0, file.seek(-32, c.SEEK_CUR));
    try std.testing.expectEqual(16, file.read(&buf));
    try std.testing.expectEqualStrings("\xaa" ** 10 ++ "Some d", &buf);

    try std.testing.expectEqual(0, file.seek(0, c.SEEK_END));
    try std.testing.expectEqual(32, file.tell());

    try std.testing.expectEqual(-1, file.seek(33, c.SEEK_END));
    try std.testing.expectEqual(0, file.seek(32, c.SEEK_END));
    try std.testing.expectEqual(0, file.tell());

    try std.testing.expectEqual(-1, file.seek(-1, c.SEEK_SET));
    try std.testing.expectEqual(0, file.seek(0, c.SEEK_SET));
    try std.testing.expectEqual(0, file.tell());
    try std.testing.expectEqual(0, file.seek(132, c.SEEK_SET));
    try std.testing.expectEqual(132, file.tell());

    try std.testing.expectEqual(32 + @sizeOf(RamFsData), file.size());

    _ = file.close();
}
