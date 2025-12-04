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

const c = @import("libc_imports").c;

const interface = @import("interface");

const kernel = @import("../kernel.zig");

pub fn BufferedFile(comptime BufferSize: usize) type {
    const Internal = struct {
        const BufferedFileInst = interface.DeriveFromBase(kernel.fs.ReadOnlyFile, struct {
            const Self = @This();
            base: kernel.fs.ReadOnlyFile,
            _position: usize,
            _buffer: [BufferSize]u8,
            _name: []const u8,
            _end: usize,

            pub fn create(filename: []const u8) BufferedFileInst {
                const file = BufferedFileInst.init(.{
                    .base = kernel.fs.ReadOnlyFile.init(.{}),
                    ._position = 0,
                    ._buffer = .{0} ** BufferSize,
                    ._name = filename,
                    ._end = 0,
                });
                return file;
            }

            pub fn read(self: *Self, buffer: []u8) isize {
                const file_len = self._end;
                if (self._position >= file_len) {
                    return 0;
                }
                const read_length = @min(@min(self._end - self._position, self._end), buffer.len);
                @memcpy(buffer[0..read_length], self._buffer[self._position .. self._position + read_length]);
                self._position += read_length;
                return @intCast(read_length);
            }

            pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
                var new_position: isize = 0;
                switch (whence) {
                    c.SEEK_SET => {
                        new_position = @as(isize, @intCast(offset));
                    },
                    c.SEEK_CUR => {
                        new_position = @as(isize, @intCast(self._position)) + @as(isize, @intCast(offset));
                    },
                    c.SEEK_END => {
                        new_position = @as(isize, @intCast(self._end)) + @as(isize, @intCast(offset));
                    },
                    else => {
                        return kernel.errno.ErrnoSet.InvalidArgument;
                    },
                }
                if (new_position < 0) {
                    return kernel.errno.ErrnoSet.IllegalSeek;
                }
                self._position = @intCast(new_position);
                return @intCast(self._position);
            }

            pub fn tell(self: *Self) i64 {
                return @intCast(self._position);
            }

            pub fn name(self: *const Self) []const u8 {
                return self._name;
            }

            pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
                _ = self;
                _ = cmd;
                _ = data;
                return 0;
            }

            pub fn fcntl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
                _ = self;
                _ = cmd;
                _ = data;
                return 0;
            }

            pub fn size(self: *const Self) u64 {
                return self._end;
            }

            pub fn filetype(self: *const Self) kernel.fs.FileType {
                _ = self;
                return kernel.fs.FileType.File;
            }
        });
    };
    return Internal.BufferedFileInst;
}

const BufferedFileForTests = interface.DeriveFromBase(BufferedFile(128), struct {
    pub const Self = @This();
    base: BufferedFile(128),

    pub fn create(filename: []const u8) BufferedFileForTests {
        var o = BufferedFileForTests.init(.{
            .base = BufferedFile(128).InstanceType.create(filename),
        });
        _ = o.data().sync();
        return o;
    }

    pub fn sync(self: *Self) i32 {
        const buf = std.fmt.bufPrint(&interface.base(self)._buffer, "Hello buffered file", .{}) catch return -1;
        interface.base(self)._end = buf.len;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

test "BufferedFile.ShouldCreateAndReadFile" {
    var file = try BufferedFileForTests.InstanceType.create("buffered_file_test.txt").interface.new(std.testing.allocator);
    defer file.interface.delete();

    const test_data = "Hello buffered file";
    var read_buffer: [64]u8 = undefined;
    const bytes_read = file.interface.read(read_buffer[0..]);
    try std.testing.expectEqual(test_data.len, @as(usize, @intCast(bytes_read)));
    try std.testing.expectEqualSlices(u8, read_buffer[0..@intCast(bytes_read)], test_data);

    // Test seeking
    try std.testing.expectEqual(0, try file.interface.seek(0, c.SEEK_SET));
    const bytes_read_again = file.interface.read(read_buffer[0..]);
    try std.testing.expectEqual(test_data.len, @as(usize, @intCast(bytes_read_again)));
    try std.testing.expectEqualSlices(u8, read_buffer[0..@intCast(bytes_read_again)], test_data);
}

test "BufferedFile.Create.ShouldInitializeCorrectly" {
    var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
    defer file.interface.delete();

    try std.testing.expectEqualStrings("test.txt", file.interface.name());
    try std.testing.expectEqual(@as(usize, 19), file.interface.size()); // "Hello buffered file" length
    try std.testing.expectEqual(kernel.fs.FileType.File, file.interface.filetype());
}

test "BufferedFile.Name.ShouldReturnFileName" {
    var file = try BufferedFileForTests.InstanceType.create("myfile.bin").interface.new(std.testing.allocator);
    defer file.interface.delete();

    try std.testing.expectEqualStrings("myfile.bin", file.interface.name());
}

// test "BufferedFile.Filetype.ShouldReturnFile" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     try std.testing.expectEqual(kernel.fs.FileType.File, file.interface.filetype());
// }

// test "BufferedFile.Size.ShouldReturnBufferEnd" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     try std.testing.expectEqual(@as(usize, 19), file.interface.size());
// }

// test "BufferedFile.Read.ShouldReturnZeroAtEnd" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Read all content
//     var buffer: [64]u8 = undefined;
//     _ = file.interface.read(&buffer);

//     // Try to read again at end
//     const bytes_read = file.interface.read(&buffer);
//     try std.testing.expectEqual(@as(isize, 0), bytes_read);
// }

// test "BufferedFile.Read.ShouldHandlePartialReads" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Read in small chunks
//     var buffer: [5]u8 = undefined;
//     const bytes_read1 = file.interface.read(&buffer);
//     try std.testing.expectEqual(@as(isize, 5), bytes_read1);
//     try std.testing.expectEqualStrings("Hello", buffer[0..@intCast(bytes_read1)]);

//     const bytes_read2 = file.interface.read(&buffer);
//     try std.testing.expectEqual(@as(isize, 5), bytes_read2);
//     try std.testing.expectEqualStrings(" buff", buffer[0..@intCast(bytes_read2)]);
// }

// test "BufferedFile.Seek.SEEK_SET.ShouldSetAbsolutePosition" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = try file.interface.seek(6, c.SEEK_SET);
//     try std.testing.expectEqual(@as(c.off_t, 6), result);

//     var buffer: [8]u8 = undefined;
//     const bytes_read = file.interface.read(&buffer);
//     try std.testing.expectEqualStrings("buffered", buffer[0..@intCast(bytes_read)]);
// }

// test "BufferedFile.Seek.SEEK_SET.ShouldRejectNegativeOffset" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = try file.interface.seek(-5, c.SEEK_SET);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "BufferedFile.Seek.SEEK_CUR.ShouldSeekRelatively" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Seek to position 5
//     _ = try file.interface.seek(5, c.SEEK_SET);

//     // Seek forward by 2
//     _ = try file.interface.seek(2, c.SEEK_CUR);

//     var buffer: [4]u8 = undefined;
//     const bytes_read = file.interface.read(&buffer);
//     try std.testing.expectEqualStrings("uffe", buffer[0..@intCast(bytes_read)]);
// }

// test "BufferedFile.Seek.SEEK_CUR.ShouldSeekBackward" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Seek to position 10
//     _ = try file.interface.seek(10, c.SEEK_SET);

//     // Seek backward by 4
//     _ = try file.interface.seek(-4, c.SEEK_CUR);

//     var buffer: [5]u8 = undefined;
//     const bytes_read = file.interface.read(&buffer);
//     try std.testing.expectEqualStrings("buffe", buffer[0..@intCast(bytes_read)]);
// }

// test "BufferedFile.Seek.SEEK_CUR.ShouldRejectNegativeResult" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Try to seek before start
//     const result = try file.interface.seek(-10, c.SEEK_CUR);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "BufferedFile.Seek.SEEK_END.ShouldSeekFromEnd" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Seek to 5 bytes before end (size is 19, so position will be 14)
//     _ = try file.interface.seek(-5, c.SEEK_END);

//     var buffer: [10]u8 = undefined;
//     const bytes_read = file.interface.read(&buffer);
//     try std.testing.expectEqual(@as(isize, 5), bytes_read);
//     try std.testing.expectEqualStrings(" file", buffer[0..@intCast(bytes_read)]);
// }

// test "BufferedFile.Seek.InvalidWhence.ShouldReturnError" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = try file.interface.seek(0, 999);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "BufferedFile.Tell.ShouldReturnCurrentPosition" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     try std.testing.expectEqual(@as(c.off_t, 0), file.interface.tell());

//     // Read some bytes
//     var buffer: [5]u8 = undefined;
//     _ = file.interface.read(&buffer);

//     try std.testing.expectEqual(@as(c.off_t, 5), file.interface.tell());

//     // Seek
//     _ = try file.interface.seek(10, c.SEEK_SET);
//     try std.testing.expectEqual(@as(c.off_t, 10), file.interface.tell());
// }

// test "BufferedFile.Ioctl.ShouldReturnZero" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = file.interface.ioctl(0, null);
//     try std.testing.expectEqual(@as(i32, 0), result);
// }

// test "BufferedFile.Fcntl.ShouldReturnZero" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = file.interface.fcntl(0, null);
//     try std.testing.expectEqual(@as(i32, 0), result);
// }

// test "BufferedFile.MultipleReadsAndSeeks.ShouldMaintainCorrectPosition" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     var buffer: [10]u8 = undefined;

//     // Read first 5 bytes
//     _ = file.interface.read(buffer[0..5]);
//     try std.testing.expectEqual(@as(c.off_t, 5), file.interface.tell());

//     // Seek back to start
//     _ = try file.interface.seek(0, c.SEEK_SET);
//     try std.testing.expectEqual(@as(c.off_t, 0), file.interface.tell());

//     // Read again
//     const bytes_read = file.interface.read(buffer[0..10]);
//     try std.testing.expectEqual(@as(isize, 10), bytes_read);
//     try std.testing.expectEqualStrings("Hello buff", buffer[0..@intCast(bytes_read)]);
// }

// test "BufferedFile.ReadBeyondBuffer.ShouldNotCrash" {
//     var file = try BufferedFileForTests.InstanceType.create("test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Try to read more than available
//     var large_buffer: [200]u8 = undefined;
//     const bytes_read = file.interface.read(&large_buffer);

//     // Should only read what's available (19 bytes)
//     try std.testing.expectEqual(@as(isize, 19), bytes_read);
//     try std.testing.expectEqualStrings("Hello buffered file", large_buffer[0..@intCast(bytes_read)]);
// }
