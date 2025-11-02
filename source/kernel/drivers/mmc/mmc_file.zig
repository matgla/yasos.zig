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

const MmcIo = @import("mmc_io.zig").MmcIo;

const log = std.log.scoped(.@"mmc/driver");

pub const MmcFile = interface.DeriveFromBase(kernel.fs.IFile, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _name: []const u8,
    _driver: *MmcIo,
    _current_block: u32,

    pub fn create(allocator: std.mem.Allocator, driver: *MmcIo, filename: []const u8) MmcFile {
        return MmcFile.init(.{
            ._allocator = allocator,
            ._name = filename,
            ._driver = driver,
            ._current_block = 0,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, driver: *MmcIo, filename: []const u8) anyerror!kernel.fs.Node {
        const file = try create(allocator, driver, filename).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn read(self: *Self, buf: []u8) isize {
        return self._driver.read(self._current_block << 9, buf);
    }

    pub fn write(self: *Self, buf: []const u8) isize {
        return self._driver.write(self._current_block << 9, buf);
    }

    pub fn seek(self: *Self, offset: c.off_t, whence: i32) anyerror!c.off_t {
        switch (whence) {
            c.SEEK_SET => {
                if (offset < 0 or (offset >> 9) > self._driver.size_in_sectors()) {
                    return -1;
                }

                self._current_block = @intCast(offset >> 9);
            },
            c.SEEK_END => {
                log.err("SEEK_END is not implemented for MMC disk", .{});
                return -1;
            },
            c.SEEK_CUR => {
                const new_position: isize = @as(isize, @intCast(self._current_block)) + (offset >> 9);
                if (new_position < 0) {
                    return -1;
                }
                self._current_block = @intCast(new_position);
            },
            else => return -1,
        }
        return @as(c.off_t, @intCast(self._current_block)) << 9;
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
        return @intCast(self._driver.size_in_sectors() << 9);
    }

    pub fn filetype(self: *const Self) kernel.fs.FileType {
        _ = self;
        return kernel.fs.FileType.BlockDevice;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

var mmc_stub = hal.mmc.Mmc.create(.{
    .mode = .SPI,
    .pins = .{
        .clk = 0,
        .cmd = 1,
        .d0 = 2,
    },
});
var mmcio: ?MmcIo = null;

fn create_sut() !kernel.fs.IFile {
    mmcio = MmcIo.create(&mmc_stub);
    try std.testing.expectError(error.CardInitializationFailure, mmcio.?.init());

    return try MmcFile.InstanceType.create(std.testing.allocator, &mmcio.?, "mmc0").interface.new(std.testing.allocator);
}

test "MmcFile.Create.ShouldInitializeCorrectly" {
    var sut = try create_sut();
    defer mmc_stub.impl.reset();

    defer sut.interface.delete();
    try std.testing.expectEqualStrings("mmc0", sut.interface.name());
    try std.testing.expectEqual(@as(u32, 0), sut.as(MmcFile).data()._current_block);
}

// test "MmcFile.CreateNode.ShouldCreateFileNode" {
//     var sut = try MmcFile.InstanceType.create_node(std.testing.allocator, &mmcio, "mmc0");
//     defer mmc_stub.impl.reset();
//     defer sut.delete();

//     try std.testing.expect(sut.is_file());
//     const maybe_file = sut.as_file();
//     try std.testing.expect(maybe_file != null);
//     if (maybe_file) |file| {
//         try std.testing.expectEqualStrings("mmc0", file.interface.name());
//     }
// }

// test "MmcFile.Filetype.ShouldReturnBlockDevice" {
//     var file = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer file.interface.delete();
//     try std.testing.expectEqual(kernel.fs.FileType.BlockDevice, file.interface.filetype());
// }

// test "MmcFile.Sync.ShouldReturnZero" {
//     var file = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer file.interface.delete();
//     const result = file.interface.sync();
//     try std.testing.expectEqual(@as(i32, 0), result);
// }

// test "MmcFile.Tell.ShouldReturnZero" {
//     var file = try create_sut();
//     defer file.interface.delete();
//     defer mmc_stub.impl.reset();
//     const result = file.interface.tell();
//     try std.testing.expectEqual(@as(c.off_t, 0), result);
// }

// test "MmcFile.Ioctl.ShouldReturnZero" {
//     var file = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer file.interface.delete();
//     const result = file.interface.ioctl(0, null);
//     try std.testing.expectEqual(@as(i32, 0), result);
// }

// test "MmcFile.Fcntl.ShouldReturnZero" {
//     var file = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer file.interface.delete();
//     const result = file.interface.fcntl(0, null);
//     try std.testing.expectEqual(@as(i32, 0), result);
// }

// test "MmcFile.Seek.SEEK_SET.ShouldSetPosition" {
//     var file = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer file.interface.delete();

//     // Seek to block 10 (offset 5120 = 10 * 512)
//     const result = try file.interface.seek(5120, c.SEEK_SET);
//     // device is uninitialized
//     try std.testing.expectEqual(-1, result);
// }

// test "MmcFile.Seek.SEEK_SET.ShouldRejectNegativeOffset" {
//     var file = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer file.interface.delete();

//     const result = try file.interface.seek(-100, c.SEEK_SET);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "MmcFile.Seek.SEEK_CUR.ShouldSeekRelatively" {
//     var file = try create_sut();
//     defer file.interface.delete();
//     defer mmc_stub.impl.reset();
//     file.as(MmcFile).data()._current_block = 10;

//     // Seek forward by 5 blocks (2560 bytes = 5 * 512)
//     const result = try file.interface.seek(2560, c.SEEK_CUR);
//     try std.testing.expectEqual(@as(u32, 15), file.as(MmcFile).data()._current_block);
//     try std.testing.expectEqual(@as(c.off_t, 15 << 9), result);
// }

// test "MmcFile.Seek.SEEK_CUR.ShouldSeekBackward" {
//     var file = try create_sut();
//     defer file.interface.delete();
//     defer mmc_stub.impl.reset();
//     file.as(MmcFile).data()._current_block = 10;

//     // Seek backward by 5 blocks (-2560 bytes = -5 * 512)
//     const result = try file.interface.seek(-2560, c.SEEK_CUR);
//     try std.testing.expectEqual(@as(u32, 5), file.as(MmcFile).data()._current_block);
//     try std.testing.expectEqual(@as(c.off_t, 5 << 9), result);
// }

// test "MmcFile.Seek.SEEK_CUR.ShouldRejectNegativePosition" {
//     var file = try create_sut();
//     defer file.interface.delete();
//     defer mmc_stub.impl.reset();
//     file.as(MmcFile).data()._current_block = 5;

//     // Try to seek before start
//     const result = try file.interface.seek(-10240, c.SEEK_CUR);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "MmcFile.Seek.SEEK_END.ShouldReturnError" {
//     var file = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer file.interface.delete();

//     const result = try file.interface.seek(0, c.SEEK_END);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "MmcFile.Seek.InvalidWhence.ShouldReturnError" {
//     var file = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer file.interface.delete();

//     const result = try file.interface.seek(0, 999);
//     try std.testing.expectEqual(@as(c.off_t, -1), result);
// }

// test "MmcFile.Size.ShouldReturnSizeInBytes" {
//     var sut = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer sut.interface.delete();
//     try std.testing.expectEqual(0, sut.interface.size());
// }

// test "MmcFile.Read.ShouldFailWhenUninitialized" {
//     var sut = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer sut.interface.delete();
//     var buf: [512]u8 = undefined;
//     try std.testing.expectEqual(-1, sut.interface.read(&buf));
// }

// test "MmcFile.Write.ShouldFailWhenUninitialized" {
//     var sut = try create_sut();
//     defer mmc_stub.impl.reset();
//     defer sut.interface.delete();
//     var buf: [512]u8 = undefined;
//     try std.testing.expectEqual(-1, sut.interface.write(&buf));
// }
