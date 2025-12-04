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
    mapped_memory: ?usize,

    pub fn create(path: []const u8, mapped_address: ?usize) !RomfsDeviceStubFile {
        const cwd = std.fs.cwd();
        const file = try cwd.openFile(path, .{ .mode = .read_only });

        return RomfsDeviceStubFile.init(.{
            .base = kernel.fs.ReadOnlyFile.init(.{}),
            .file = file,
            .path = path,
            .mapped_memory = mapped_address,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, path: []const u8, mapped_address: ?usize) !kernel.fs.Node {
        const file_instance = try (try create(path, mapped_address)).interface.new(allocator);
        return kernel.fs.Node.create_file(file_instance);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        return @intCast(self.file.?.read(buffer) catch return -1);
    }

    pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
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

    pub fn tell(self: *Self) i64 {
        return @intCast(self.file.?.getPos() catch return 0);
    }

    pub fn size(self: *const Self) u64 {
        return @intCast(self.file.?.getEndPos() catch return 0);
    }

    pub fn name(self: *const Self) []const u8 {
        return std.fs.path.basename(self.path);
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        switch (cmd) {
            @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus) => {
                if (data) |ptr| {
                    const status: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(ptr));
                    if (self.mapped_memory) |addr| {
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
        return kernel.fs.FileType.File;
    }

    pub fn dupe(self: *Self) ?IFile {
        return self.new(self.allocator) catch return null;
    }

    pub fn delete(self: *Self) void {
        _ = self.file.?.close();
    }

    pub fn load(self: *Self) !void {
        _ = self;
    }
});

pub const RomfsDeviceStub = interface.DeriveFromBase(IDriver, struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    _node: kernel.fs.Node,

    pub fn init(allocator: std.mem.Allocator, path: [:0]const u8, mapped_address: ?usize) !RomfsDeviceStub {
        return RomfsDeviceStub.init(.{
            .allocator = allocator,
            ._node = try RomfsDeviceStubFile.InstanceType.create_node(allocator, path, mapped_address),
        });
    }

    pub fn destroy(self: *Self) void {
        if (self.file) |file| {
            file.close();
        }
    }

    pub fn load(self: *Self) anyerror!void {
        var file = self._node.as_file().?;
        try file.as(RomfsDeviceStubFile).data().load();
    }

    pub fn unload(self: *Self) bool {
        _ = self;
        return true;
    }

    pub fn node(self: *Self) anyerror!kernel.fs.Node {
        return self._node;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "romfs";
    }
});
