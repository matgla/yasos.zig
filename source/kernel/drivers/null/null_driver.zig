//
// null_driver.zig
//
// Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

// `/dev/null` and `/dev/zero`: the two memory character devices POSIX shell
// scripts take for granted. Without `/dev/null` every `2>/dev/null` fails
// (the open falls through to O_CREAT on the read-only driverfs: EROFS), which
// stops an autoconf `configure` on its first probe.
//
//   null: reads hit end-of-file, writes are accepted and discarded.
//   zero: reads return zero bytes, writes are accepted and discarded.

const std = @import("std");

const interface = @import("interface");

const c = @import("libc_imports").c;

const IDriver = @import("../idriver.zig").IDriver;
const IFile = @import("../../fs/ifile.zig").IFile;
const FileType = @import("../../fs/ifile.zig").FileType;
const PollMask = @import("../../fs/ifile.zig").PollMask;
const poll_always_ready = @import("../../fs/ifile.zig").poll_always_ready;

const kernel = @import("../../kernel.zig");

pub const MemoryDevice = enum { null, zero };

pub const MemoryDeviceFile = interface.DeriveFromBase(IFile, struct {
    const Self = @This();
    _kind: MemoryDevice,
    _name: []const u8,

    pub fn create(kind: MemoryDevice, filename: []const u8) MemoryDeviceFile {
        return MemoryDeviceFile.init(.{
            ._kind = kind,
            ._name = filename,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, kind: MemoryDevice, filename: []const u8) anyerror!kernel.fs.Node {
        const file = try create(kind, filename).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        switch (self._kind) {
            .null => return 0,
            .zero => {
                @memset(buffer, 0);
                return @intCast(buffer.len);
            },
        }
    }

    pub fn write(self: *Self, data: []const u8) isize {
        _ = self;
        return @intCast(data.len);
    }

    /// Any position is accepted and there is nothing to be positioned in, so
    /// every seek lands on 0 -- what Linux reports for these devices. The
    /// O_TRUNC / O_APPEND handling in open seeks, so this must not fail.
    pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
        _ = self;
        _ = offset;
        _ = whence;
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
        _ = self;
        _ = cmd;
        _ = arg;
        return -1;
    }

    pub fn fcntl(self: *Self, op: i32, maybe_arg: ?*anyopaque) i32 {
        _ = self;
        _ = maybe_arg;
        return switch (op) {
            c.F_GETFL, c.F_SETFL => 0,
            else => -1,
        };
    }

    pub fn size(self: *const Self) u64 {
        _ = self;
        return 0;
    }

    /// `>/dev/null` opens with O_TRUNC, which truncates to 0: a no-op here.
    pub fn truncate(self: *Self, length: u64) anyerror!void {
        _ = self;
        _ = length;
    }

    pub fn poll(self: *Self, events: PollMask) PollMask {
        _ = self;
        return poll_always_ready(events);
    }

    pub fn filetype(self: *const Self) FileType {
        _ = self;
        return FileType.CharDevice;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

pub const MemoryDeviceDriver = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();

    _name: []const u8,
    _node: kernel.fs.Node,

    pub fn create(allocator: std.mem.Allocator, kind: MemoryDevice, driver_name: []const u8) !MemoryDeviceDriver {
        return MemoryDeviceDriver.init(.{
            ._name = driver_name,
            ._node = try MemoryDeviceFile.InstanceType.create_node(allocator, kind, driver_name),
        });
    }

    pub fn delete(self: *Self) void {
        self._node.delete();
    }

    pub fn node(self: *Self) anyerror!kernel.fs.Node {
        return try self._node.clone();
    }

    pub fn load(self: *Self) anyerror!void {
        _ = self;
    }

    pub fn unload(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }
});

fn create_test_file(kind: MemoryDevice) !IFile {
    return try MemoryDeviceFile.InstanceType.create(kind, @tagName(kind)).interface.new(std.testing.allocator);
}

test "MemoryDevice.Null.ReadsEndOfFile" {
    var file = try create_test_file(.null);
    defer file.interface.delete();

    var buffer: [8]u8 = @splat(0xaa);
    try std.testing.expectEqual(@as(isize, 0), file.interface.read(buffer[0..]));
    try std.testing.expectEqual(@as(u8, 0xaa), buffer[0]);
}

test "MemoryDevice.Null.DiscardsWrites" {
    var file = try create_test_file(.null);
    defer file.interface.delete();

    try std.testing.expectEqual(@as(isize, 5), file.interface.write("hello"));
    try std.testing.expectEqual(@as(u64, 0), file.interface.size());
}

test "MemoryDevice.Zero.ReadsZeros" {
    var file = try create_test_file(.zero);
    defer file.interface.delete();

    var buffer: [8]u8 = @splat(0xaa);
    try std.testing.expectEqual(@as(isize, 8), file.interface.read(buffer[0..]));
    const zeros: [8]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, zeros[0..], buffer[0..]);
    try std.testing.expectEqual(@as(isize, 3), file.interface.write("abc"));
}

test "MemoryDevice.OpenForWriting.TruncateAndSeekSucceed" {
    var file = try create_test_file(.null);
    defer file.interface.delete();

    try file.interface.truncate(0);
    try std.testing.expectEqual(@as(i64, 0), try file.interface.seek(0, c.SEEK_END));
    try std.testing.expectEqual(FileType.CharDevice, file.interface.filetype());
}

test "MemoryDeviceDriver.Node.IsCharDevice" {
    var driver = try (try MemoryDeviceDriver.InstanceType.create(std.testing.allocator, .null, "null")).interface.new(std.testing.allocator);
    defer driver.interface.delete();

    try std.testing.expectEqualStrings("null", driver.interface.name());
    var node = try driver.interface.node();
    defer node.delete();
    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("null", node.name());
    try std.testing.expectEqual(FileType.CharDevice, node.filetype());
}
