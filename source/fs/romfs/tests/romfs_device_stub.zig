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

const kernel = @import("kernel");
const IDriver = kernel.driver.IDriver;
const IFile = kernel.fs.IFile;

const interface = @import("interface");

pub const RomfsDeviceStubFile = interface.DeriveFromBase(kernel.fs.ReadOnlyFile, struct {
    const Self = @This();
    base: kernel.fs.ReadOnlyFile,
    file: ?std.fs.File,
    path: []const u8,

    pub fn init(path: []const u8) RomfsDeviceStubFile {
        return RomfsDeviceStubFile.init(.{
            .base = kernel.fs.ReadOnlyFile.init(.{}),
            .file = null,
            .path = path,
        });
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        return @intCast(self.file.?.read(buffer) catch return -1);
    }

    pub fn seek(self: *Self, offset: c.off_t, whence: i32) c.off_t {
        switch (whence) {
            c.SEEK_SET => {
                self.file.?.seekTo(@intCast(offset)) catch return -1;
            },
            c.SEEK_END => {
                self.file.?.seekFromEnd(@intCast(offset)) catch return -1;
            },
            c.SEEK_CUR => {
                self.file.?.seekBy(@intCast(offset)) catch return -1;
            },
            else => return -1,
        }
        return offset;
    }

    pub fn close(self: *Self) void {
        self.file.?.close();
    }

    pub fn tell(self: *Self) c.off_t {
        return @intCast(self.file.?.getPos() catch return 0);
    }

    pub fn size(self: *Self) isize {
        return @intCast(self.file.?.getEndPos() catch return 0);
    }

    pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
        _ = allocator;
        return kernel.fs.FileName.init(std.fs.path.basename(self.path), null);
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

    pub fn stat(self: *Self, buf: *c.struct_stat) void {
        _ = self;
        buf.st_dev = 0;
        buf.st_ino = 0;
        buf.st_mode = 0;
        buf.st_nlink = 0;
        buf.st_uid = 0;
        buf.st_gid = 0;
        buf.st_rdev = 0;
        buf.st_size = 0;
        buf.st_blksize = 1;
        buf.st_blocks = 1;
    }

    pub fn filetype(self: *Self) kernel.fs.FileType {
        _ = self;
        return kernel.fs.FileType.File;
    }

    pub fn dupe(self: *Self) ?IFile {
        return self.new(self.allocator) catch return null;
    }

    pub fn delete(self: *Self) void {
        _ = self.file.?.close();
    }

    pub fn load(self: *Self) !void {
        const cwd = std.fs.cwd();
        self.file = try cwd.openFile(self.path, .{ .mode = .read_only });
    }
});

pub const RomfsDeviceStub = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();
    allocator: *const std.mem.Allocator,
    file: RomfsDeviceStubFile,

    pub fn init(allocator: *const std.mem.Allocator, path: [:0]const u8) RomfsDeviceStub {
        return RomfsDeviceStub.init(.{
            .allocator = allocator,
            .file = RomfsDeviceStubFile.InstanceType.init(path),
        });
    }

    pub fn destroy(self: *Self) void {
        if (self.file) |file| {
            file.close();
        }
    }

    pub fn load(self: *Self) anyerror!void {
        try self.file.data().load();
    }

    pub fn unload(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn ifile(self: *Self, allocator: std.mem.Allocator) ?IFile {
        return self.file.interface.new(allocator) catch return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "romfs";
    }
});
