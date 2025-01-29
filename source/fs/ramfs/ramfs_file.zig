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
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
});

const IFile = @import("../../kernel/fs/ifile.zig").IFile;
const RamFsData = @import("ramfs_data.zig").RamFsData;

const RamFsFile = struct {
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
        .stat = stat,
    };

    /// Pointer to data instance, data is kept by filesystem
    data: *RamFsData,

    /// Current position in file
    position: usize = 0,

    pub fn create(data: *RamFsData) RamFsFile {
        return .{
            .data = data,
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
        if (self.position >= self.data.data.items.len) {
            return 0;
        }
        const length = @min(self.data.data.items.len - self.position, buffer.len);
        @memcpy(buffer[0..length], self.data.data.items[self.position .. self.position + length]);
        self.position += length;
        return @intCast(length);
    }

    pub fn write(ctx: *anyopaque, data: []const u8) isize {
        const self: *RamFsFile = @ptrCast(@alignCast(ctx));
        if (self.data.data.items.len < data.len + self.position) {
            self.data.data.resize(self.position + data.len) catch {
                return 0;
            };
        }
        self.data.data.replaceRange(self.position, data.len, data) catch {
            return 0;
        };
        self.position += data.len;
        return @intCast(data.len);
    }

    pub fn seek(ctx: *anyopaque, offset: c.off_t, whence: i32) c.off_t {
        const self: *RamFsFile = @ptrCast(@alignCast(ctx));
        switch (whence) {
            c.SEEK_SET => {
                if (offset < 0) {
                    return -1;
                }
                self.position = @intCast(offset);
            },
            c.SEEK_END => {
                if (self.data.data.items.len >= offset) {
                    self.position = self.data.data.items.len - @as(usize, @intCast(offset));
                } else {
                    // set errno
                    return -1;
                }
            },
            c.SEEK_CUR => {
                const new_position = @as(c.off_t, @intCast(self.position)) + offset;
                if (new_position < 0) {
                    return -1;
                }
                self.position = @intCast(new_position);
            },
            else => return -1,
        }
        return 0;
    }

    pub fn close(_: *anyopaque) i32 {
        return 0;
    }

    pub fn sync(_: *anyopaque) i32 {
        return 0;
    }

    pub fn tell(ctx: *const anyopaque) c.off_t {
        const self: *const RamFsFile = @ptrCast(@alignCast(ctx));
        return @intCast(self.position);
    }

    pub fn size(_: *const anyopaque) isize {
        return 0;
    }

    pub fn name(_: *const anyopaque) []const u8 {
        return "";
    }

    pub fn ioctl(_: *anyopaque, _: u32, _: *const anyopaque) i32 {
        return 0;
    }

    pub fn stat(_: *const anyopaque, _: *c.struct_stat) void {}
};

test "Read and write file" {
    var data = try RamFsData.create_file(std.testing.allocator, "test_file");
    defer data.deinit();

    var sut = RamFsFile.create(&data);
    const file = sut.ifile();
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
}
