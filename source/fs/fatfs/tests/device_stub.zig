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

const kernel = @import("kernel");

pub const FatFsDeviceFileStub = interface.DeriveFromBase(kernel.fs.IFile, struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),
    position: isize,
    refcounter: *usize,
    mapped_address: ?usize,

    pub fn create(allocator: std.mem.Allocator, mapped_address: ?usize) !FatFsDeviceFileStub {
        const counter = try allocator.create(usize);
        counter.* = 1;
        const dsize = 1024 * 1024 * 40;
        var array = try std.ArrayList(u8).initCapacity(allocator, dsize);

        _ = array.addManyAtBounded(0, dsize) catch {
            allocator.destroy(counter);
            return error.OutOfMemory;
        };

        return FatFsDeviceFileStub.init(.{
            .allocator = allocator,
            .data = array,
            .position = 0,
            .refcounter = counter,
            .mapped_address = mapped_address,
        });
    }

    pub fn __clone(self: *Self, other: *const Self) void {
        self.* = other.*;
        self.refcounter.* += 1;
    }

    pub fn create_node(allocator: std.mem.Allocator) !kernel.fs.Node {
        const file_instance = try (try create(allocator)).interface.new(allocator);
        return kernel.fs.Node.create_file(file_instance);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        if (self.position >= @as(isize, @intCast(self.data.items.len))) {
            return 0;
        }
        const length = @min(buffer.len, @as(usize, @intCast(self.data.items.len - @as(usize, @intCast(self.position)))));
        @memcpy(buffer[0..length], self.data.items[@as(usize, @intCast(self.position)) .. @as(usize, @intCast(self.position)) + length]);
        self.position += @as(isize, @intCast(length));
        return @as(isize, @intCast(length));
    }

    pub fn write(self: *Self, buffer: []const u8) isize {
        const length = buffer.len;
        const required_capacity = @as(usize, @intCast(self.position)) + length;
        if (required_capacity > self.data.items.len) {
            return 0;
        }
        self.data.replaceRange(self.allocator, @as(usize, @intCast(self.position)), length, buffer) catch {
            return 0;
        };
        self.position += @as(isize, @intCast(length));
        return @as(isize, @intCast(length));
    }

    pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
        switch (whence) {
            c.SEEK_SET => {
                self.position = @as(isize, @intCast(offset));
            },
            c.SEEK_END => {
                self.position = @as(isize, @intCast(self.data.items.len)) + @as(isize, @intCast(offset));
            },
            c.SEEK_CUR => {
                self.position += @as(isize, @intCast(offset));
            },
            else => return -1,
        }
        return @intCast(self.position);
    }

    pub fn tell(self: *Self) i64 {
        return @intCast(self.position);
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "fatfs_device_stub";
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        switch (cmd) {
            @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus) => {
                if (data) |ptr| {
                    const status: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(ptr));
                    if (self.mapped_address) |addr| {
                        status.* = .{
                            .is_memory_mapped = true,
                            .mapped_address_r = @ptrFromInt(addr),
                            .mapped_address_w = @ptrFromInt(addr),
                        };
                        return 0;
                    }
                    return 0;
                }
            },
            else => {
                return 0;
            },
        }
        return 0;
    }

    pub fn fcntl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        _ = self;
        _ = cmd;
        _ = data;
        return 0;
    }

    pub fn filetype(self: *const Self) kernel.fs.FileType {
        _ = self;
        return kernel.fs.FileType.BlockDevice;
    }

    pub fn size(self: *const Self) u64 {
        return self.data.capacity;
    }

    pub fn sync(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn close(self: *Self) void {
        _ = self;
    }

    pub fn delete(self: *Self) void {
        self.refcounter.* -= 1;
        if (self.refcounter.* == 0) {
            self.data.deinit(self.allocator);
            self.allocator.destroy(self.refcounter);
        }
    }
});
