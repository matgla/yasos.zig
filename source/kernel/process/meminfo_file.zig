// Copyright (c) 2025 Mateusz Stadnik
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

const std = @import("std");

const c = @import("libc_imports").c;
const interface = @import("interface");

const kernel = @import("../kernel.zig");

const log = std.log.scoped(.@"vfs/meminfo");

const MemoryInfo = struct {
    free: usize,
    total: usize,
};

pub const MemInfoFile = struct {
    const Self = @This();
    const BufferSize = 128;
    pub usingnamespace interface.DeriveFromBase(kernel.fs.ReadOnlyFile, MemInfoFile);
    base: kernel.fs.ReadOnlyFile,
    _position: usize = 0,
    _buffer: [BufferSize]u8,

    pub fn create() MemInfoFile {
        var meminfo = MemInfoFile{
            .base = .{},
            ._position = 0,
            ._buffer = .{0} ** BufferSize,
        };

        _ = std.fmt.bufPrint(&meminfo._buffer, "MemUsed: {:>16} kB", .{kernel.memory.heap.malloc.get_usage()}) catch {};
        return meminfo;
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        const file_len = std.mem.sliceTo(&self._buffer, 0).len;
        if (self._position >= file_len) {
            return 0;
        }
        const read_length = @min(self._buffer.len - self._position, buffer.len);
        @memcpy(buffer, self._buffer[self._position .. self._position + read_length]);
        self._position += read_length;
        return @intCast(read_length);
    }

    pub fn seek(self: *Self, offset: c.off_t, whence: i32) c.off_t {
        _ = self;
        _ = offset;
        _ = whence;
        return 0;
    }

    pub fn close(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn tell(self: *Self) c.off_t {
        return @intCast(self._position);
    }

    pub fn size(self: *Self) isize {
        return @intCast(std.mem.sliceTo(&self._buffer, 0).len);
    }

    pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
        _ = allocator;
        _ = self;
        return .{ ._allocator = null, ._name = "meminfo" };
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

    pub fn dupe(self: *Self) ?kernel.fs.IFile {
        return self.new(self.allocator) catch return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
};
