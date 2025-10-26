//
// ramfs_file.zig
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
const fatfs = @import("zfat");

const c = @import("libc_imports").c;

const kernel = @import("kernel");

const log = kernel.log;

pub const FatFsFile = interface.DeriveFromBase(kernel.fs.IFile, struct {
    const Self = @This();
    _file: ?fatfs.File,
    _allocator: std.mem.Allocator,
    _is_open: bool,
    _name: []const u8,
    _filetype: kernel.fs.FileType,

    pub fn create(allocator: std.mem.Allocator, path: [:0]const u8) !FatFsFile {
        const filename = try allocator.dupe(u8, std.fs.path.basename(path));
        errdefer allocator.free(filename);
        const file = try fatfs.File.open(path, .{ .access = .read_write, .mode = .open_existing });
        return FatFsFile.init(.{
            ._file = file,
            ._allocator = allocator,
            ._is_open = true,
            ._name = filename,
            ._filetype = .File,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, path: [:0]const u8) anyerror!kernel.fs.Node {
        const file = try (try create(allocator, path)).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        if (self._file) |*file| {
            const s = file.read(buffer) catch return -1;
            return @as(isize, @intCast(s));
        }
        return 0;
    }

    pub fn write(self: *Self, data: []const u8) isize {
        if (self._file) |*file| {
            const s = file.write(data) catch return -1;
            return @as(isize, @intCast(s));
        }

        return 0;
    }

    pub fn seek(self: *Self, offset: c.off_t, whence: i32) anyerror!c.off_t {
        if (self._file) |*file| {
            switch (whence) {
                c.SEEK_SET => {
                    file.seekTo(@intCast(offset)) catch return -1;
                    return self.tell();
                },
                c.SEEK_END => {
                    const file_size: c.off_t = @intCast(file.size());
                    if (file_size >= offset) {
                        file.seekTo(@intCast(file_size - @as(c.off_t, @intCast(offset)))) catch return -1;
                        return self.tell();
                    } else {
                        // set errno
                        return -1;
                    }
                },
                c.SEEK_CUR => {
                    const new_position = @as(c.off_t, @intCast(file.tell())) + offset;
                    if (new_position < 0) {
                        return -1;
                    }
                    file.seekTo(@intCast(new_position)) catch return -1;
                    return self.tell();
                },
                else => return -1,
            }
            return -1;
        }
        return 0;
    }

    pub fn close(self: *Self) void {
        if (!self._is_open) {
            return;
        }
        self._is_open = false;
        if (self._file) |*file| {
            file.close();
            self._file = null;
        }
    }

    pub fn sync(self: *Self) i32 {
        if (self._file) |*file| {
            file.sync() catch return -1;
        }
        return 0;
    }

    pub fn tell(self: *Self) c.off_t {
        if (self._file) |*file| {
            return @intCast(file.tell());
        }
        return 0;
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        _ = self;
        switch (cmd) {
            @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus) => {
                var attr: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(data));
                attr.is_memory_mapped = false;
            },
            else => {
                return -1;
            },
        }
        return 0;
    }

    pub fn fcntl(self: *Self, _: i32, _: ?*anyopaque) i32 {
        _ = self;
        return 0;
    }

    pub fn filetype(self: *const Self) kernel.fs.FileType {
        return self._filetype;
    }

    pub fn delete(self: *Self) void {
        _ = self.close();
        self._allocator.free(self._name);
    }

    pub fn stat(self: *Self, data: *c.struct_stat) void {
        if (self._file) |*file| {
            data.st_size = @as(usize, @intCast(file.size()));
        }
    }
});
