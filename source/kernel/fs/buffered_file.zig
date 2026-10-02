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
const vfmt = @import("../vfmt.zig");

const c = @import("libc_imports").c;

const interface = @import("interface");

const kernel = @import("../kernel.zig");

/// A read-only file whose whole content is rendered by `sync` into one buffer
/// (the /proc files).
///
/// The buffer lives on the kernel heap only while the file is open: `buffer()`
/// allocates it the first time `sync` renders, `delete` gives it back. The
/// instance a directory keeps to hand out clones never syncs, so it costs the
/// object alone -- these used to carry the buffer inline, and the /proc root's
/// dozen files held ~9 KB of the kernel heap for the whole run, plus a full
/// copy per open.
///
/// A clone is a plain copy of the object (libs/oop `dupe`), so it would share
/// the original's buffer. `_owner` records which instance allocated it; any
/// other instance treats the buffer as absent and allocates its own, which
/// makes cloning a synced file safe as well as cheap.
pub fn BufferedFile(comptime BufferSize: usize) type {
    const Internal = struct {
        const BufferedFileInst = interface.DeriveFromBase(kernel.fs.ReadOnlyFile, struct {
            const Self = @This();
            base: kernel.fs.ReadOnlyFile,
            _position: usize,
            _allocator: std.mem.Allocator,
            _storage: ?*[BufferSize]u8,
            _owner: ?*const Self,
            _name: []const u8,
            _end: usize,

            pub fn create(allocator: std.mem.Allocator, filename: []const u8) BufferedFileInst {
                const file = BufferedFileInst.init(.{
                    .base = kernel.fs.ReadOnlyFile.init(.{}),
                    ._position = 0,
                    ._allocator = allocator,
                    ._storage = null,
                    ._owner = null,
                    ._name = filename,
                    ._end = 0,
                });
                return file;
            }

            /// The buffer this instance renders into, allocated on first use.
            /// Null when the heap cannot spare it; `sync` then leaves the file
            /// empty.
            pub fn buffer(self: *Self) ?*[BufferSize]u8 {
                if (self.content_storage()) |storage| return storage;
                self._storage = self._allocator.create([BufferSize]u8) catch {
                    self._storage = null;
                    self._owner = null;
                    self._end = 0;
                    return null;
                };
                self._owner = self;
                return self._storage;
            }

            fn content_storage(self: *const Self) ?*[BufferSize]u8 {
                if (self._owner != self) return null;
                return self._storage;
            }

            fn content(self: *const Self) []const u8 {
                const storage = self.content_storage() orelse return &.{};
                return storage[0..@min(self._end, BufferSize)];
            }

            pub fn delete(self: *Self) void {
                if (self.content_storage()) |storage| self._allocator.destroy(storage);
                self._storage = null;
                self._owner = null;
                self._end = 0;
            }

            pub fn read(self: *Self, buffer_out: []u8) isize {
                const data = self.content();
                if (self._position >= data.len) {
                    return 0;
                }
                const read_length = @min(data.len - self._position, buffer_out.len);
                @memcpy(buffer_out[0..read_length], data[self._position .. self._position + read_length]);
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
                        new_position = @as(isize, @intCast(self.content().len)) + @as(isize, @intCast(offset));
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
                return self.content().len;
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

    pub fn create(allocator: std.mem.Allocator, filename: []const u8) BufferedFileForTests {
        return BufferedFileForTests.init(.{
            .base = BufferedFile(128).InstanceType.create(allocator, filename),
        });
    }

    pub fn sync(self: *Self) i32 {
        const buffer = interface.base(self).buffer() orelse return -1;
        const buf = vfmt.print(buffer, "Hello buffered file", .{});
        interface.base(self)._end = buf.len;
        return 0;
    }

    pub fn delete(self: *Self) void {
        interface.base(self).delete();
    }
});

test "BufferedFile.ShouldCreateAndReadFile" {
    var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "buffered_file_test.txt").interface.new(std.testing.allocator);
    defer file.interface.delete();
    _ = file.interface.sync();

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
    var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
    defer file.interface.delete();
    _ = file.interface.sync();

    try std.testing.expectEqualStrings("test.txt", file.interface.name());
    try std.testing.expectEqual(@as(usize, 19), file.interface.size()); // "Hello buffered file" length
    try std.testing.expectEqual(kernel.fs.FileType.File, file.interface.filetype());
}

test "BufferedFile.HoldsNoBufferUntilSynced" {
    var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "lazy.txt").interface.new(std.testing.allocator);
    defer file.interface.delete();

    try std.testing.expectEqual(@as(u64, 0), file.interface.size());
    var read_buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), file.interface.read(read_buffer[0..]));
}

test "BufferedFile.CloneOfASyncedFileRendersIntoItsOwnBuffer" {
    var original = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "shared.txt").interface.new(std.testing.allocator);
    _ = original.interface.sync();

    // A clone is a byte copy of the object; the buffer pointer it carries is
    // the original's, which it must neither read nor free.
    var copy = try original.clone();
    defer copy.interface.delete();
    try std.testing.expectEqual(@as(u64, 0), copy.interface.size());

    original.interface.delete();
    _ = copy.interface.sync();
    var read_buffer: [64]u8 = undefined;
    const bytes_read = copy.interface.read(read_buffer[0..]);
    try std.testing.expectEqualStrings("Hello buffered file", read_buffer[0..@intCast(bytes_read)]);
}

test "BufferedFile.Name.ShouldReturnFileName" {
    var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "myfile.bin").interface.new(std.testing.allocator);
    defer file.interface.delete();
    _ = file.interface.sync();

    try std.testing.expectEqualStrings("myfile.bin", file.interface.name());
}

// test "BufferedFile.Filetype.ShouldReturnFile" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     try std.testing.expectEqual(kernel.fs.FileType.File, file.interface.filetype());
// }

// test "BufferedFile.Size.ShouldReturnBufferEnd" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     try std.testing.expectEqual(@as(usize, 19), file.interface.size());
// }

// test "BufferedFile.Read.ShouldReturnZeroAtEnd" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Read all content
//     var buffer: [64]u8 = undefined;
//     _ = file.interface.read(&buffer);

//     // Try to read again at end
//     const bytes_read = file.interface.read(&buffer);
//     try std.testing.expectEqual(@as(isize, 0), bytes_read);
// }

// test "BufferedFile.Read.ShouldHandlePartialReads" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
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
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = try file.interface.seek(6, c.SEEK_SET);
//     try std.testing.expectEqual(@as(c.off_t, 6), result);

//     var buffer: [8]u8 = undefined;
//     const bytes_read = file.interface.read(&buffer);
//     try std.testing.expectEqualStrings("buffered", buffer[0..@intCast(bytes_read)]);
// }

// test "BufferedFile.Seek.SEEK_SET.ShouldRejectNegativeOffset" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = try file.interface.seek(-5, c.SEEK_SET);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "BufferedFile.Seek.SEEK_CUR.ShouldSeekRelatively" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
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
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
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
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Try to seek before start
//     const result = try file.interface.seek(-10, c.SEEK_CUR);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "BufferedFile.Seek.SEEK_END.ShouldSeekFromEnd" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Seek to 5 bytes before end (size is 19, so position will be 14)
//     _ = try file.interface.seek(-5, c.SEEK_END);

//     var buffer: [10]u8 = undefined;
//     const bytes_read = file.interface.read(&buffer);
//     try std.testing.expectEqual(@as(isize, 5), bytes_read);
//     try std.testing.expectEqualStrings(" file", buffer[0..@intCast(bytes_read)]);
// }

// test "BufferedFile.Seek.InvalidWhence.ShouldReturnError" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = try file.interface.seek(0, 999);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "BufferedFile.Tell.ShouldReturnCurrentPosition" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
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
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = file.interface.ioctl(0, null);
//     try std.testing.expectEqual(@as(i32, 0), result);
// }

// test "BufferedFile.Fcntl.ShouldReturnZero" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     const result = file.interface.fcntl(0, null);
//     try std.testing.expectEqual(@as(i32, 0), result);
// }

// test "BufferedFile.MultipleReadsAndSeeks.ShouldMaintainCorrectPosition" {
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
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
//     var file = try BufferedFileForTests.InstanceType.create(std.testing.allocator, "test.txt").interface.new(std.testing.allocator);
//     defer file.interface.delete();

//     // Try to read more than available
//     var large_buffer: [200]u8 = undefined;
//     const bytes_read = file.interface.read(&large_buffer);

//     // Should only read what's available (19 bytes)
//     try std.testing.expectEqual(@as(isize, 19), bytes_read);
//     try std.testing.expectEqualStrings("Hello buffered file", large_buffer[0..@intCast(bytes_read)]);
// }
