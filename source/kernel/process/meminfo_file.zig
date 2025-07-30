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

pub const MemInfoFile = interface.DeriveFromBase(kernel.fs.ReadOnlyFile, struct {
    const Self = @This();
    const BufferSize = 128;
    base: kernel.fs.ReadOnlyFile,
    _position: usize,
    _buffer: [BufferSize]u8,

    pub fn create() MemInfoFile {
        var meminfo = MemInfoFile.init(.{
            .base = kernel.fs.ReadOnlyFile.init(.{}),
            ._position = 0,
            ._buffer = .{0} ** BufferSize,
        });

        const memory_used: usize = kernel.memory.heap.malloc.get_usage();
        const memory_used_slow = kernel.process.process_manager.instance.get_process_memory_pool().get_used_size();
        const memory_used_combined = memory_used + memory_used_slow;
        var written_length: usize = 0;
        var sizebuf = [_]u8{0} ** 16;
        var buf = std.fmt.bufPrint(&meminfo.data()._buffer, "MemUsed:         {s}\n", .{format_size(memory_used_combined, &sizebuf)}) catch
            &meminfo.data()._buffer;
        written_length += buf.len;
        buf = std.fmt.bufPrint(meminfo.data()._buffer[written_length..], "MemKernelUsed:   {s}\n", .{format_size(memory_used, &sizebuf)}) catch buf;
        written_length += buf.len;
        _ = std.fmt.bufPrint(meminfo.data()._buffer[written_length..], "MemProcessUsed:  {s}\n", .{format_size(memory_used_slow, &sizebuf)}) catch {};

        return meminfo;
    }

    fn format_size(memsize: u64, buffer: []u8) []const u8 {
        if (memsize >= 1000000000000) {
            return std.fmt.bufPrint(buffer, "---", .{}) catch buffer[0..];
        } else if (memsize >= 1024 * 1024 * 1024) {
            return std.fmt.bufPrint(buffer, "{d: >8} MB", .{memsize / 1024 / 1024}) catch buffer[0..];
        } else if (memsize >= 1024 * 1024) {
            return std.fmt.bufPrint(buffer, "{d: >8} KB", .{memsize / 1024}) catch buffer[0..];
        } else {
            return std.fmt.bufPrint(buffer, "{d: >8} B", .{memsize}) catch buffer[0..];
        }

        return buffer;
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        const file_len = std.mem.sliceTo(&self._buffer, 0).len;
        if (self._position >= file_len) {
            return 0;
        }
        const read_length = @min(self._buffer.len - self._position, buffer.len);
        @memcpy(buffer[0..read_length], self._buffer[self._position .. self._position + read_length]);
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
});
