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

pub const RomFsFile = struct {
    const Self = @This();
    pub usingnamespace interface.DeriveFromBase(ReadOnlyFile, Self);
    base: ReadOnlyFile,
    /// Pointer to data instance, data is kept by filesystem
    header: FileHeader,
    allocator: std.mem.Allocator,

    /// Current position in file
    position: c.off_t = 0,

    // RomFsFile interface
    pub fn create(header: FileHeader, allocator: std.mem.Allocator) RomFsFile {
        return .{
            .base = .{},
            .header = header,
            .allocator = allocator,
        };
    }

    pub fn read(self: *RomFsFile, buffer: []u8) isize {
        const data_size: c.off_t = @intCast(self.header.size());
        if (self.position >= data_size) {
            return 0;
        }
        const length = @min(data_size - self.position, buffer.len);
        self.header.read_bytes(buffer, self.position);
        self.position += length;
        return @intCast(length);
    }

    pub fn seek(self: *Self, offset: c.off_t, whence: i32) c.off_t {
        switch (whence) {
            c.SEEK_SET => {
                if (offset < 0) {
                    return -1;
                }
                self.position = @intCast(offset);
            },
            c.SEEK_END => {
                const file_size: c.off_t = @intCast(self.header.size());
                if (file_size >= offset) {
                    self.position = file_size - @as(c.off_t, @intCast(offset));
                } else {
                    // set errno
                    return -1;
                }
            },
            c.SEEK_CUR => {
                const new_position = @as(c.off_t, @intCast(self.position)) + offset;
                if (new_position < 0) {
                    return -1;
                }
                self.position = @intCast(new_position);
            },
            else => return -1,
        }
        return 0;
    }

    pub fn close(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn tell(self: *Self) c.off_t {
        return @intCast(self.position);
    }

    pub fn size(self: *Self) isize {
        return @intCast(self.header.size());
    }

    pub fn name(self: *Self) FileName {
        return self.header.name();
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        switch (cmd) {
            @intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus) => {
                var attr: *FileMemoryMapAttributes = @ptrCast(@alignCast(data));
                if (self.header.get_mapped_address()) |address| {
                    attr.is_memory_mapped = true;
                    attr.mapped_address_r = address;
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

    pub fn stat(self: *Self, buf: *c.struct_stat) void {
        buf.st_dev = 0;
        buf.st_ino = 0;
        buf.st_mode = 0;
        buf.st_nlink = 0;
        buf.st_uid = 0;
        buf.st_gid = 0;
        buf.st_rdev = 0;
        buf.st_size = @intCast(self.header.size());
        buf.st_blksize = 1;
        buf.st_blocks = 1;
    }

    pub fn filetype(self: *Self) FileType {
        return self.header.filetype();
    }

    pub fn dupe(self: *Self) ?IFile {
        return self.new(self.allocator) catch return null;
    }

    pub fn delete(self: *Self) void {
        self.close();
    }
};
