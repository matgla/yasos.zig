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

// /proc/<pid>/maps — dumps the load addresses of the executable and shared
// libraries loaded for a process, one "<module> <section> 0x<addr> 0x<size>"
// line per section. This is the on-demand replacement for the loader's old
// "[ERR][yasld] .text loaded at ..." log spam: consumers (e.g. GDB symbol
// loading in scripts/yasld_gdb.py) can read this instead of parsing the UART.

const std = @import("std");

const c = @import("libc_imports").c;
const interface = @import("interface");

const kernel = @import("../kernel.zig");

const log = std.log.scoped(.@"vfs/procfs/maps");

// Large enough for an executable plus its shared libraries (each module is five
// short lines). Output is truncated gracefully if a process ever exceeds this.
const BufferSize = 4096;
const MapsBufferedFile = kernel.fs.BufferedFile(BufferSize);

pub const MapsFile = interface.DeriveFromBase(MapsBufferedFile, struct {
    const Self = @This();
    base: MapsBufferedFile,
    _pid: i16,

    pub fn create(pid: i16) MapsFile {
        var file = MapsFile.init(.{
            .base = MapsBufferedFile.InstanceType.create("maps"),
            ._pid = pid,
        });
        _ = file.data().sync();
        return file;
    }

    pub fn create_node(allocator: std.mem.Allocator, pid: i16) anyerror!kernel.fs.Node {
        const file = try create(pid).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        var buffer = &interface.base(self)._buffer;
        const written = kernel.dynamic_loader.format_maps(@intCast(self._pid), buffer[0..]);
        interface.base(self)._end = written;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
