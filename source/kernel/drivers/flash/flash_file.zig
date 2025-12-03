//
// uart_file.zig
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

const std = @import("std");

const interface = @import("interface");

const c = @import("libc_imports").c;

const IFile = @import("../../fs/ifile.zig").IFile;
const FileName = @import("../../fs/ifile.zig").FileName;
const FileType = @import("../../fs/ifile.zig").FileType;
const IoctlCommonCommands = @import("../../fs/ifile.zig").IoctlCommonCommands;
const FileMemoryMapAttributes = @import("../../fs/ifile.zig").FileMemoryMapAttributes;

const kernel = @import("../../kernel.zig");

const log = std.log.scoped(.@"kernel/fs/driver/flash_file");

pub fn FlashFile(comptime FlashType: anytype) type {
    const Internal = struct {
        const FlashFileImpl = interface.DeriveFromBase(IFile, struct {
            const Self = @This();
            _flash: FlashType,
            _allocator: std.mem.Allocator,
            _current_address: u32,
            _name: []const u8,

            pub fn create(allocator: std.mem.Allocator, flash: FlashType, filename: []const u8) FlashFileImpl {
                return FlashFileImpl.init(.{
                    ._flash = flash,
                    ._allocator = allocator,
                    ._current_address = 0,
                    ._name = filename,
                });
            }

            pub fn create_node(allocator: std.mem.Allocator, flash: FlashType, filename: []const u8) anyerror!kernel.fs.Node {
                const file = try create(allocator, flash, filename).interface.new(allocator);
                return kernel.fs.Node.create_file(file);
            }

            // IFile interface
            pub fn read(self: *Self, buffer: []u8) isize {
                self._flash.read(self._current_address, buffer);
                self._current_address += @intCast(buffer.len);
                return @intCast(buffer.len);
            }

            pub fn write(self: *Self, data: []const u8) isize {
                self._flash.write(self._current_address, data);
                self._current_address += @intCast(data.len);
                return @intCast(data.len);
            }

            pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
                switch (whence) {
                    c.SEEK_SET => {
                        if (offset < 0) {
                            return kernel.errno.ErrnoSet.IllegalSeek;
                        }
                        self._current_address = @intCast(offset);
                    },
                    else => return kernel.errno.ErrnoSet.IllegalSeek,
                }
                return 0;
            }

            pub fn sync(self: *Self) i32 {
                _ = self;
                return 0;
            }

            pub fn tell(self: *Self) i64 {
                _ = self;
                return 0;
            }

            pub fn name(self: *const Self) []const u8 {
                return self._name;
            }

            pub fn ioctl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
                switch (cmd) {
                    @intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus) => {
                        if (arg == null) {
                            return -1;
                        }
                        var attr: *FileMemoryMapAttributes = @ptrCast(@alignCast(arg.?));
                        attr.is_memory_mapped = true;
                        attr.mapped_address_r = self._flash.get_physical_address().ptr;
                    },
                    else => {
                        return -1;
                    },
                }
                return 0;
            }

            pub fn fcntl(self: *Self, op: i32, maybe_arg: ?*anyopaque) i32 {
                _ = self;
                _ = op;
                _ = maybe_arg;
                return -1;
            }

            pub fn size(self: *const Self) u64 {
                return FlashType.BlockSize * self._flash.get_number_of_blocks();
            }

            pub fn filetype(self: *const Self) FileType {
                _ = self;
                return FileType.BlockDevice;
            }

            pub fn delete(self: *Self) void {
                log.debug("Flash file 0x{x} destruction", .{@intFromPtr(self)});
            }
        });
    };
    return Internal.FlashFileImpl;
}

const FlashMock = @import("tests/FlashMock.zig").FlashMock;
const hal = @import("hal");
const MockFlash = hal.flash.Flash(FlashMock);
const TestFlashFile = FlashFile(MockFlash);

fn create_sut() !kernel.fs.IFile {
    const flash = MockFlash.create(0);
    return try TestFlashFile.InstanceType.create(std.testing.allocator, flash, "flash0").interface.new(std.testing.allocator);
}

test "FlashFile.Create.ShouldInitializeCorrectly" {
    var file = try create_sut();
    defer file.interface.delete();

    try std.testing.expectEqualStrings("flash0", file.interface.name());
    try std.testing.expectEqual(@as(u32, 0), file.as(TestFlashFile).data()._current_address);
}

test "FlashFile.CreateNode.ShouldCreateFileNode" {
    const flash = MockFlash.create(0);
    var node = try TestFlashFile.InstanceType.create_node(std.testing.allocator, flash, "flash1");
    defer node.delete();
    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("flash1", node.name());
    try std.testing.expectEqual(FileType.BlockDevice, node.filetype());
}

test "FlashFile.Filetype.ShouldReturnBlockDevice" {
    var file = try create_sut();
    defer file.interface.delete();

    try std.testing.expectEqual(FileType.BlockDevice, file.interface.filetype());
}

test "FlashFile.Size.ShouldReturnFlashSize" {
    var file = try create_sut();
    defer file.interface.delete();

    // 1 block * 4096 bytes = 4096
    const expected_size = FlashMock.BlockSize * 1;
    try std.testing.expectEqual(@as(usize, expected_size), file.interface.size());
}

test "FlashFile.Read.ShouldReadFromFlash" {
    var file = try create_sut();
    defer file.interface.delete();

    // First write some data
    const write_data = "test flash data";
    _ = file.interface.write(write_data);

    // Reset position
    _ = try file.interface.seek(0, c.SEEK_SET);

    // Read it back
    var buffer: [32]u8 = undefined;
    const bytes_read = file.interface.read(&buffer);

    try std.testing.expectEqual(@as(isize, 32), bytes_read);
    try std.testing.expectEqualStrings(write_data, buffer[0..write_data.len]);
}

test "FlashFile.Write.ShouldWriteToFlash" {
    var file = try create_sut();
    defer file.interface.delete();

    const data = "flash write test";
    const bytes_written = file.interface.write(data);

    try std.testing.expectEqual(@as(isize, @intCast(data.len)), bytes_written);
    try std.testing.expectEqual(@as(u32, @intCast(data.len)), file.as(TestFlashFile).data()._current_address);
}

test "FlashFile.Seek.SEEK_SET.ShouldSetPosition" {
    var file = try create_sut();
    defer file.interface.delete();

    const result = try file.interface.seek(100, c.SEEK_SET);
    try std.testing.expectEqual(@as(c.off_t, 0), result);
    try std.testing.expectEqual(@as(u32, 100), file.as(TestFlashFile).data()._current_address);
}

test "FlashFile.Seek.InvalidWhence.ShouldReturnError" {
    var file = try create_sut();
    defer file.interface.delete();

    const result = file.interface.seek(100, c.SEEK_CUR);
    try std.testing.expectEqual(kernel.errno.ErrnoSet.IllegalSeek, result);
}

test "FlashFile.Read.ShouldAdvancePosition" {
    var file = try create_sut();
    defer file.interface.delete();

    var buffer: [16]u8 = undefined;
    _ = file.interface.read(&buffer);

    try std.testing.expectEqual(@as(u32, 16), file.as(TestFlashFile).data()._current_address);

    _ = file.interface.read(&buffer);
    try std.testing.expectEqual(@as(u32, 32), file.as(TestFlashFile).data()._current_address);
}

test "FlashFile.ReadWrite.ShouldMaintainDataIntegrity" {
    var file = try create_sut();
    defer file.interface.delete();

    const test_data = "Hello Flash!";

    // Write data at offset 0
    _ = file.interface.write(test_data);

    // Seek back to start
    _ = try file.interface.seek(0, c.SEEK_SET);

    // Read it back
    var buffer: [32]u8 = undefined;
    _ = file.interface.read(&buffer);

    try std.testing.expectEqualStrings(test_data, buffer[0..test_data.len]);
}

test "FlashFile.Ioctl.GetMemoryMappingStatus.ShouldReturnMappedAddress" {
    var file = try create_sut();
    defer file.interface.delete();

    var attr: FileMemoryMapAttributes = undefined;
    const result = file.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), @ptrCast(&attr));

    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect(attr.is_memory_mapped);
    try std.testing.expect(attr.mapped_address_r != null);
}

test "FlashFile.Ioctl.InvalidCommand.ShouldReturnError" {
    var file = try create_sut();
    defer file.interface.delete();

    const result = file.interface.ioctl(999, null);
    try std.testing.expectEqual(@as(i32, -1), result);
}

test "FlashFile.Fcntl.ShouldReturnError" {
    var file = try create_sut();
    defer file.interface.delete();

    const result = file.interface.fcntl(0, null);
    try std.testing.expectEqual(@as(i32, -1), result);
}

test "FlashFile.Sync.ShouldReturnZero" {
    var file = try create_sut();
    defer file.interface.delete();

    const result = file.interface.sync();
    try std.testing.expectEqual(@as(i32, 0), result);
}

test "FlashFile.Tell.ShouldReturnZero" {
    var file = try create_sut();
    defer file.interface.delete();

    const result = file.interface.tell();
    try std.testing.expectEqual(@as(c.off_t, 0), result);
}

test "FlashFile.MultipleReadWrites.ShouldHandleSequentialAccess" {
    var file = try create_sut();
    defer file.interface.delete();

    // Write multiple chunks
    const chunk1 = "AAA";
    const chunk2 = "BBB";
    const chunk3 = "CCC";

    _ = file.interface.write(chunk1);
    _ = file.interface.write(chunk2);
    _ = file.interface.write(chunk3);

    // Seek to start
    _ = try file.interface.seek(0, c.SEEK_SET);

    // Read back all data
    var buffer: [16]u8 = undefined;
    _ = file.interface.read(&buffer);

    try std.testing.expectEqualStrings("AAABBBCCC", buffer[0..9]);
}
