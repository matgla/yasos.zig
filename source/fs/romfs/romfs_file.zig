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
const c = @import("../../libc_imports.zig").c;

const IFile = @import("../../kernel/fs/ifile.zig").IFile;
const FileType = @import("../../kernel/fs/ifile.zig").FileType;
const FileHeader = @import("file_header.zig").FileHeader;
const IoctlCommonCommands = @import("../../kernel/fs/ifile.zig").IoctlCommonCommands;
const FileMemoryMapAttributes = @import("../../kernel/fs/ifile.zig").FileMemoryMapAttributes;

pub const RomFsFile = struct {
    /// VTable for IFile interface
    const VTable = IFile.VTable{
        .read = read,
        .write = write,
        .seek = seek,
        .close = close,
        .sync = sync,
        .tell = tell,
        .size = size,
        .name = name,
        .ioctl = ioctl,
        .fcntl = fcntl,
        .stat = stat,
        .filetype = filetype,
        .dupe = dupe,
        .destroy = destroy,
    };

    /// Pointer to data instance, data is kept by filesystem
    data: FileHeader,
    allocator: std.mem.Allocator,

    /// Current position in file
    position: usize = 0,

    pub fn create(data: FileHeader, allocator: std.mem.Allocator) RomFsFile {
        return .{
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn ifile(self: *RomFsFile) IFile {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    pub fn read(ctx: *anyopaque, buffer: []u8) isize {
        const self: *RomFsFile = @ptrCast(@alignCast(ctx));
        if (self.position >= self.data.size()) {
            return 0;
        }
        const length = @min(self.data.size() - self.position, buffer.len);
        @memcpy(buffer[0..length], self.data.data()[self.position .. self.position + length]);
        self.position += length;
        return @intCast(length);
    }

    pub fn write(_: *anyopaque, _: []const u8) isize {
        return -1;
    }

    pub fn seek(ctx: *anyopaque, offset: c.off_t, whence: i32) c.off_t {
        const self: *RomFsFile = @ptrCast(@alignCast(ctx));
        switch (whence) {
            c.SEEK_SET => {
                if (offset < 0) {
                    return -1;
                }
                self.position = @intCast(offset);
            },
            c.SEEK_END => {
                if (self.data.size() >= offset) {
                    self.position = self.data.size() - @as(usize, @intCast(offset));
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

    pub fn close(ctx: *anyopaque) i32 {
        const self: *RomFsFile = @ptrCast(@alignCast(ctx));
        self.allocator.destroy(self);
        return 0;
    }

    pub fn sync(_: *anyopaque) i32 {
        // always in sync
        return 0;
    }

    pub fn tell(ctx: *const anyopaque) c.off_t {
        const self: *const RomFsFile = @ptrCast(@alignCast(ctx));
        return @intCast(self.position);
    }

    pub fn size(ctx: *const anyopaque) isize {
        const self: *const RomFsFile = @ptrCast(@alignCast(ctx));
        return @intCast(self.data.size());
    }

    pub fn name(ctx: *const anyopaque) []const u8 {
        const self: *const RomFsFile = @ptrCast(@alignCast(ctx));
        return self.data.name();
    }

    pub fn ioctl(ctx: *anyopaque, cmd: i32, data: ?*anyopaque) i32 {
        const self: *const RomFsFile = @ptrCast(@alignCast(ctx));
        switch (cmd) {
            @intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus) => {
                var attr: *FileMemoryMapAttributes = @ptrCast(@alignCast(data));
                attr.is_memory_mapped = true;
                attr.mapped_address_r = self.data.data().ptr;
            },
            else => {
                return -1;
            },
        }
        return 0;
    }

    pub fn fcntl(ctx: *anyopaque, cmd: i32, data: ?*anyopaque) i32 {
        _ = ctx;
        _ = cmd;
        _ = data;
        return 0;
    }

    pub fn stat(ctx: *const anyopaque, buf: *c.struct_stat) void {
        const self: *const RomFsFile = @ptrCast(@alignCast(ctx));
        buf.st_dev = 0;
        buf.st_ino = 0;
        buf.st_mode = 0;
        buf.st_nlink = 0;
        buf.st_uid = 0;
        buf.st_gid = 0;
        buf.st_rdev = 0;
        buf.st_size = @intCast(self.data.size());
        buf.st_blksize = 1;
        buf.st_blocks = 1;
    }

    pub fn filetype(ctx: *const anyopaque) FileType {
        const self: *const RomFsFile = @ptrCast(@alignCast(ctx));
        return self.data.filetype();
    }

    pub fn dupe(ctx: *anyopaque) ?IFile {
        const self: *RomFsFile = @ptrCast(@alignCast(ctx));
        const new_file = self.allocator.create(RomFsFile) catch return null;
        new_file.* = self.*;
        return new_file.ifile();
    }

    pub fn destroy(ctx: *anyopaque) void {
        const self: *RomFsFile = @ptrCast(@alignCast(ctx));
        self.allocator.destroy(self);
    }
};
