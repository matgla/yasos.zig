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

const BufferSize = 128;
const BufferedFileForMeminfo = kernel.fs.BufferedFile(BufferSize);
pub const MemInfoFile = interface.DeriveFromBase(BufferedFileForMeminfo, struct {
    const Self = @This();
    base: BufferedFileForMeminfo,

    pub fn create() MemInfoFile {
        var meminfo = MemInfoFile.init(.{
            .base = BufferedFileForMeminfo.InstanceType.create("meminfo"),
        });
        _ = meminfo.data().sync();
        return meminfo;
    }
    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create().interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const memory_used: usize = kernel.memory.heap.malloc.get_usage();
        const memory_used_slow = kernel.process.process_manager.instance.get_process_memory_pool().get_used_size();
        const memory_used_combined = memory_used + memory_used_slow;
        var buffer = &interface.base(self)._buffer;
        var written_length: usize = 0;
        var sizebuf = [_]u8{0} ** 16;
        var buf = std.fmt.bufPrint(buffer, "MemUsed:         {s}\n", .{format_size(memory_used_combined, &sizebuf)}) catch
            buffer;
        written_length += buf.len;
        buf = std.fmt.bufPrint(buffer[written_length..], "MemKernelUsed:   {s}\n", .{format_size(memory_used, &sizebuf)}) catch buf;
        written_length += buf.len;
        buf = std.fmt.bufPrint(buffer[written_length..], "MemProcessUsed:  {s}\n", .{format_size(memory_used_slow, &sizebuf)}) catch buf;
        written_length += buf.len;
        interface.base(self)._end = written_length;
        return 0;
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

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
