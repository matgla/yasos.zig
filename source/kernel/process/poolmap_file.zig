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

// `/proc/poolmap` -- every live mapping of the process page pool, one per line:
// pid, tier (0 fast SRAM, 1 PSRAM), address, bytes, source.  `/proc/meminfo`
// says how much is in use; this says whose it is, which is what decides how much
// of the fast tier a compile can have.

const std = @import("std");

const interface = @import("interface");

const kernel = @import("../kernel.zig");

const BufferSize = 4096;
const PoolMapBufferedFile = kernel.fs.BufferedFile(BufferSize);

pub const PoolMapFile = interface.DeriveFromBase(PoolMapBufferedFile, struct {
    const Self = @This();
    base: PoolMapBufferedFile,

    pub fn create(allocator: std.mem.Allocator) PoolMapFile {
        return PoolMapFile.init(.{
            .base = PoolMapBufferedFile.InstanceType.create(allocator, "poolmap"),
        });
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create(allocator).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const buffer = interface.base(self).buffer() orelse return -1;
        var written: usize = 0;
        if (kernel.process.process_manager.is_initialized()) {
            written = kernel.process.process_manager.instance.get_process_memory_pool().write_map(buffer);
        }
        interface.base(self)._end = written;
        return 0;
    }

    pub fn delete(self: *Self) void {
        interface.base(self).delete();
    }
});
