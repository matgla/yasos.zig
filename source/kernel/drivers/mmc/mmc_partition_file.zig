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

const hal = @import("hal");
const interface = @import("interface");

const kernel = @import("../../kernel.zig");

const log = std.log.scoped(.@"mmc/file");

pub const MmcPartitionFile =
    interface.DeriveFromBase(kernel.fs.IFile, struct {
        const Self = @This();

        /// VTable for IFile interface
        _name: []const u8,
        _dev: kernel.fs.IFile,
        _start_lba: u32,
        _size_in_sectors: u32,
        _current_position: c.off_t,

        pub fn create(filename: []const u8, dev: kernel.fs.IFile, start_lba: u32, size_in_sectors: u32) MmcPartitionFile {
            return MmcPartitionFile.init(.{
                ._name = filename,
                ._dev = dev,
                ._start_lba = start_lba,
                ._size_in_sectors = size_in_sectors,
                ._current_position = @as(c.off_t, @intCast(start_lba)) << 9,
            });
        }

        pub fn __clone(self: *Self, other: *Self) void {
            self._name = other._name;
            self._dev = other._dev.share();
            self._start_lba = other._start_lba;
            self._size_in_sectors = other._size_in_sectors;
            self._current_position = 0;
        }

        pub fn create_node(allocator: std.mem.Allocator, dev: kernel.fs.IFile, filename: []const u8, start_lba: u32, size_in_sectors: u32) anyerror!kernel.fs.Node {
            const file = try create(filename, dev, start_lba, size_in_sectors).interface.new(allocator);
            return kernel.fs.Node.create_file(file);
        }

        pub fn read(self: *Self, buf: []u8) isize {
            _ = self._dev.interface.seek(self._current_position, c.SEEK_SET) catch return 0;
            const readed = self._dev.interface.read(buf);
            self._current_position += readed;
            return readed;
        }

        pub fn write(self: *Self, buf: []const u8) isize {
            _ = self._dev.interface.seek(self._current_position, c.SEEK_SET) catch return 0;
            const written = self._dev.interface.write(buf);
            self._current_position += written;
            return written;
        }

        pub fn seek(self: *Self, offset: c.off_t, base: i32) anyerror!c.off_t {
            if ((self._start_lba << 9) + offset > (self._start_lba + self._size_in_sectors) << 9) {
                kernel.log.err("Seek offset {d} is out of bounds for MMC partition file", .{offset});
                return kernel.errno.ErrnoSet.InvalidArgument;
            }
            if (@as(c.off_t, @intCast(self._start_lba)) + (offset >> 9) < @as(c.off_t, @intCast(self._start_lba))) {
                kernel.log.err("Seek offset {d} is before the start of MMC partition file", .{offset});
                return kernel.errno.ErrnoSet.InvalidArgument;
            }
            const seek_offset = (@as(c.off_t, @intCast(self._start_lba)) << 9) + offset;
            self._current_position = try self._dev.interface.seek(seek_offset, base);
            return self._current_position;
        }

        pub fn sync(self: *Self) i32 {
            _ = self;
            return 0;
        }

        pub fn tell(self: *Self) c.off_t {
            _ = self;
            return 0;
        }

        pub fn name(self: *const Self) []const u8 {
            return self._name;
        }

        pub fn ioctl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
            _ = self;
            _ = cmd;
            _ = arg;
            return 0;
        }

        pub fn fcntl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
            _ = self;
            _ = cmd;
            _ = arg;
            return 0;
        }

        pub fn size(self: *const Self) usize {
            return @as(usize, @intCast(self._size_in_sectors)) << 9;
        }

        pub fn filetype(self: *const Self) kernel.fs.FileType {
            _ = self;
            return kernel.fs.FileType.BlockDevice;
        }

        pub fn delete(self: *Self) void {
            self._dev.interface.delete();
        }
    });

const FileMock = @import("../../fs/tests/file_mock.zig").FileMock;

fn create_sut(start_lba: u32, size_in_sectors: u32) !struct { file: kernel.fs.IFile, mock: *FileMock } {
    var mock_dev = try FileMock.create(std.testing.allocator);
    const dev_interface = mock_dev.get_interface();
    const partition_file = try MmcPartitionFile.InstanceType.create("partition0", dev_interface, start_lba, size_in_sectors).interface.new(std.testing.allocator);
    return .{ .file = partition_file, .mock = mock_dev };
}

test "MmcPartitionFile.Create.ShouldInitializeCorrectly" {
    const result = try create_sut(100, 200);
    var sut = result.file;
    defer sut.interface.delete();

    try std.testing.expectEqualStrings("partition0", sut.interface.name());
    try std.testing.expectEqual(@as(u32, 100), sut.as(MmcPartitionFile).data()._start_lba);
    try std.testing.expectEqual(@as(u32, 200), sut.as(MmcPartitionFile).data()._size_in_sectors);
    try std.testing.expectEqual(@as(c.off_t, 100 << 9), sut.as(MmcPartitionFile).data()._current_position);
}

test "MmcPartitionFile.CreateNode.ShouldCreateFileNode" {
    var mock_dev = try FileMock.create(std.testing.allocator);
    const dev_interface = mock_dev.get_interface();

    var sut = try MmcPartitionFile.InstanceType.create_node(std.testing.allocator, dev_interface, "partition1", 50, 100);
    defer sut.delete();

    try std.testing.expect(sut.is_file());
    const maybe_file = sut.as_file();
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |file| {
        try std.testing.expectEqualStrings("partition1", file.interface.name());
    }
}

test "MmcPartitionFile.Filetype.ShouldReturnBlockDevice" {
    const result = try create_sut(0, 100);
    var file = result.file;
    defer file.interface.delete();

    try std.testing.expectEqual(kernel.fs.FileType.BlockDevice, file.interface.filetype());
}

test "MmcPartitionFile.Size.ShouldReturnSizeInBytes" {
    const result = try create_sut(100, 200);
    var file = result.file;
    defer file.interface.delete();

    // 200 sectors * 512 bytes = 102400 bytes
    try std.testing.expectEqual(@as(usize, 200 << 9), file.interface.size());
    try std.testing.expectEqual(@as(usize, 102400), file.interface.size());
}

test "MmcPartitionFile.Read.ShouldReadFromPartitionOffset" {
    const result = try create_sut(100, 200);
    var file = result.file;
    const mock = result.mock;
    defer file.interface.delete();

    _ = mock.expectCall("seek")
        .withArgs(.{ @as(c.off_t, 100 << 9), c.SEEK_SET })
        .willReturn(@as(c.off_t, 100 << 9));

    _ = mock.expectCall("read")
        .willReturn(@as(isize, 512));

    var buffer: [512]u8 = undefined;
    const bytes_read = file.interface.read(&buffer);

    try std.testing.expectEqual(@as(isize, 512), bytes_read);
}

test "MmcPartitionFile.Write.ShouldWriteToPartitionOffset" {
    const result = try create_sut(100, 200);
    var file = result.file;
    const mock = result.mock;
    defer file.interface.delete();

    const data = "test data for partition write";

    _ = mock.expectCall("seek")
        .withArgs(.{ @as(c.off_t, 100 << 9), c.SEEK_SET })
        .willReturn(@as(c.off_t, 100 << 9));

    _ = mock.expectCall("write")
        .willReturn(@as(isize, @intCast(data.len)));

    const bytes_written = file.interface.write(data);

    try std.testing.expectEqual(@as(isize, @intCast(data.len)), bytes_written);
}

test "MmcPartitionFile.Seek.SEEK_SET.ShouldSeekRelativeToPartitionStart" {
    const sut = try create_sut(100, 200);
    var file = sut.file;
    const mock = sut.mock;
    defer file.interface.delete();

    _ = mock.expectCall("seek")
        .withArgs(.{ @as(c.off_t, 56320), c.SEEK_SET })
        .willReturn(@as(c.off_t, 56320));

    // Seek to offset 10 blocks (5120 bytes) from partition start
    const result = try file.interface.seek(5120, c.SEEK_SET);

    // Should be at partition_start (100) + offset (10) = block 110
    // Which is 110 * 512 = 56320 bytes from device start
    try std.testing.expectEqual(@as(c.off_t, 56320), result);
}

test "MmcPartitionFile.Seek.SEEK_SET.ShouldRejectOffsetBeyondPartition" {
    const sut = try create_sut(100, 200);
    var file = sut.file;
    defer file.interface.delete();

    // Try to seek beyond partition end (200 sectors = 102400 bytes)
    const result = file.interface.seek(160000, c.SEEK_SET);

    try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, result);
}

test "MmcPartitionFile.Seek.SEEK_SET.ShouldRejectNegativeOffset" {
    const sut = try create_sut(100, 200);
    var file = sut.file;
    defer file.interface.delete();

    // Try to seek before partition start
    const result = file.interface.seek(-1000, c.SEEK_SET);

    try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, result);
}

test "MmcPartitionFile.Seek.SEEK_CUR.ShouldSeekRelatively" {
    const sut = try create_sut(100, 200);
    var file = sut.file;
    const mock = sut.mock;
    defer file.interface.delete();

    _ = mock.expectCall("seek")
        .withArgs(.{ @as(c.off_t, 53248), c.SEEK_SET })
        .willReturn(@as(c.off_t, 53248));

    _ = mock.expectCall("seek")
        .withArgs(.{ @as(c.off_t, 54272), c.SEEK_SET })
        .willReturn(@as(c.off_t, 54272));

    // First seek to a known position
    _ = try file.interface.seek(2048, c.SEEK_SET);

    // Then seek forward by 1024 bytes
    const result = try file.interface.seek(1024, c.SEEK_CUR);

    // Should be at partition start (100*512=51200) + initial(2048) + offset(1024) = 54272
    try std.testing.expectEqual(@as(c.off_t, 54272), result);
}

test "MmcPartitionFile.ReadWrite.ShouldMaintainPosition" {
    const sut = try create_sut(100, 200);
    var file = sut.file;
    const mock = sut.mock;
    defer file.interface.delete();

    const write_data = "test data";

    _ = mock.expectCall("seek")
        .withArgs(.{ @as(c.off_t, 100 << 9), c.SEEK_SET })
        .willReturn(@as(c.off_t, 100 << 9));

    _ = mock.expectCall("write")
        .willReturn(@as(isize, @intCast(write_data.len)));

    _ = file.interface.write(write_data);

    // Position should have advanced
    const pos_after_write = @as(c.off_t, @intCast((100 << 9) + write_data.len));
    try std.testing.expectEqual(pos_after_write, file.as(MmcPartitionFile).data()._current_position);

    _ = mock.expectCall("seek")
        .willReturn(@as(c.off_t, pos_after_write));

    _ = mock.expectCall("read")
        .willReturn(@as(isize, 512));

    var read_buffer: [512]u8 = undefined;
    _ = file.interface.read(&read_buffer);

    // Position should have advanced further
    const pos_after_read = pos_after_write + 512;
    try std.testing.expectEqual(pos_after_read, file.as(MmcPartitionFile).data()._current_position);
}

test "MmcPartitionFile.Sync.ShouldReturnZero" {
    const sut = try create_sut(100, 200);
    var file = sut.file;
    defer file.interface.delete();

    const result = file.interface.sync();
    try std.testing.expectEqual(@as(i32, 0), result);
}

test "MmcPartitionFile.Tell.ShouldReturnZero" {
    const sut = try create_sut(100, 200);
    var file = sut.file;
    defer file.interface.delete();

    const result = file.interface.tell();
    try std.testing.expectEqual(@as(c.off_t, 0), result);
}

test "MmcPartitionFile.Ioctl.ShouldReturnZero" {
    const sut = try create_sut(100, 200);
    var file = sut.file;
    defer file.interface.delete();

    const result = file.interface.ioctl(0, null);
    try std.testing.expectEqual(@as(i32, 0), result);
}

test "MmcPartitionFile.Fcntl.ShouldReturnZero" {
    const sut = try create_sut(100, 200);
    var file = sut.file;
    defer file.interface.delete();

    const result = file.interface.fcntl(0, null);
    try std.testing.expectEqual(@as(i32, 0), result);
}

test "MmcPartitionFile.Clone.ShouldCreateIndependentCopy" {
    const sut = try create_sut(100, 200);
    var file1 = sut.file;
    const mock = sut.mock;
    defer file1.interface.delete();

    _ = mock.expectCall("seek")
        .withArgs(.{ @as(c.off_t, 56320), c.SEEK_SET })
        .willReturn(@as(c.off_t, 56320));

    // Advance position on first file
    _ = try file1.interface.seek(5120, c.SEEK_SET);

    // Clone should start with fresh position
    var file2 = try file1.clone();
    defer file2.interface.delete();

    try std.testing.expectEqual(@as(c.off_t, 0), file2.as(MmcPartitionFile).data()._current_position);
    try std.testing.expectEqual(@as(u32, 100), file2.as(MmcPartitionFile).data()._start_lba);
    try std.testing.expectEqual(@as(u32, 200), file2.as(MmcPartitionFile).data()._size_in_sectors);
}

test "MmcPartitionFile.PartitionBoundaries.ShouldEnforceStartAndEnd" {
    const sut = try create_sut(100, 50);
    var file = sut.file;
    const mock = sut.mock;
    defer file.interface.delete();

    // Partition is blocks 100-149 (50 blocks)
    // Valid offsets are 0 to (50*512 - 1) = 0 to 25599

    _ = mock.expectCall("seek")
        .withArgs(.{ @as(c.off_t, (100 + 49) << 9), c.SEEK_SET })
        .willReturn(@as(c.off_t, (100 + 49) << 9));

    // Test at boundary
    const result1 = try file.interface.seek(25088, c.SEEK_SET); // 49 blocks
    try std.testing.expectEqual(@as(c.off_t, (100 + 49) << 9), result1);

    // Test beyond boundary
    const result2 = file.interface.seek(26000, c.SEEK_SET);
    try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, result2);
}
