//
// romfs_file.zig
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

const interface = @import("interface");

const c = @import("libc_imports").c;

const kernel = @import("kernel");

const IFile = kernel.IFile;
const ReadOnlyFile = kernel.fs.ReadOnlyFile;
const FileType = kernel.fs.FileType;
const FileName = kernel.fs.FileName;
const FileHeader = @import("file_header.zig").FileHeader;
const IoctlCommonCommands = kernel.fs.IoctlCommonCommands;
const FileMemoryMapAttributes = kernel.fs.FileMemoryMapAttributes;

const log = std.log;

pub const RomFsFile = interface.DeriveFromBase(ReadOnlyFile, struct {
    const Self = @This();
    base: ReadOnlyFile,
    /// Pointer to data instance, data is kept by filesystem
    header: FileHeader,
    allocator: std.mem.Allocator,

    /// Current position in file
    position: c.off_t,

    // RomFsFile interface
    pub fn create(allocator: std.mem.Allocator, header: FileHeader) RomFsFile {
        return RomFsFile.init(.{
            .base = ReadOnlyFile.init(.{}),
            .header = header,
            .allocator = allocator,
            .position = 0,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, header: FileHeader) anyerror!kernel.fs.Node {
        const file = try create(allocator, header).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        const data_size: c.off_t = @intCast(self.header.size());
        if (self.position >= data_size) {
            return 0;
        }
        const length = @min(data_size - self.position, buffer.len);
        self.header.read_bytes(buffer, self.position) catch return 0;
        self.position += length;
        return @intCast(length);
    }

    pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
        var new_position: c.off_t = 0;
        const file_size: c.off_t = @intCast(self.header.size());
        switch (whence) {
            c.SEEK_SET => {
                new_position = @intCast(offset);
            },
            c.SEEK_END => {
                new_position = file_size + @as(c.off_t, @intCast(offset));
            },
            c.SEEK_CUR => {
                new_position = @as(c.off_t, @intCast(self.position)) + @as(c.off_t, @intCast(offset));
            },
            else => return kernel.errno.ErrnoSet.InvalidArgument,
        }
        if (new_position < 0 or new_position > file_size) {
            return kernel.errno.ErrnoSet.InvalidArgument;
        }
        self.position = new_position;
        return @intCast(self.position);
    }

    pub fn tell(self: *Self) i64 {
        return @intCast(self.position);
    }

    pub fn name(self: *const Self) []const u8 {
        return self.header.name();
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        switch (cmd) {
            @intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus) => {
                if (data == null) {
                    return -1;
                }
                var attr: *FileMemoryMapAttributes = @ptrCast(@alignCast(data.?));
                if (self.header.get_mapped_address()) |address| {
                    attr.is_memory_mapped = true;
                    attr.mapped_address_r = address;
                    attr.mapped_address_w = null;
                } else {
                    attr.is_memory_mapped = false;
                }
            },
            else => {
                return -1;
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

    pub fn filetype(self: *const Self) FileType {
        return self.header.filetype();
    }

    pub fn delete(self: *Self) void {
        self.header.deinit();
    }

    pub fn size(self: *const Self) u64 {
        return @as(u64, @intCast(self.header.size()));
    }
});
