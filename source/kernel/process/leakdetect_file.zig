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
const vfmt = @import("../vfmt.zig");

const interface = @import("interface");

const kernel = @import("../kernel.zig");

const BufferSize = 128;
const BufferedFile = kernel.fs.BufferedFile(BufferSize);

const TheKernelAllocator = kernel.memory.heap.malloc.KernelAllocatorType;

pub const LeakStartFile = interface.DeriveFromBase(BufferedFile, struct {
    const Self = @This();
    base: BufferedFile,

    pub fn create() LeakStartFile {
        var file = LeakStartFile.init(.{
            .base = BufferedFile.InstanceType.create("leakstart"),
        });
        _ = file.data().sync();
        return file;
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create().interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        TheKernelAllocator.start_leaks_detection();
        const buffer = &interface.base(self)._buffer;
        var written_length: usize = 0;
        const buf = vfmt.print(buffer, "leak detection started\n", .{});
        written_length += buf.len;
        interface.base(self)._end = written_length;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

pub const LeakDumpFile = interface.DeriveFromBase(BufferedFile, struct {
    const Self = @This();
    base: BufferedFile,

    pub fn create() LeakDumpFile {
        var file = LeakDumpFile.init(.{
            .base = BufferedFile.InstanceType.create("leakdump"),
        });
        _ = file.data().sync();
        return file;
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create().interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    fn is_pid_alive(pid: i32) bool {
        if (kernel.process.process_manager.instance.get_process_for_pid(pid)) |p| {
            return p.state != .Terminated;
        }
        return false;
    }

    pub fn sync(self: *Self) i32 {
        const leaked = TheKernelAllocator.detect_leaks_filter(&is_pid_alive);
        const buffer = &interface.base(self)._buffer;
        var written_length: usize = 0;
        const buf = vfmt.print(buffer, "leaked: {d} bytes\n", .{leaked});
        written_length += buf.len;
        interface.base(self)._end = written_length;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
