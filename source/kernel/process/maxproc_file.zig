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

const config = @import("config");

const MemoryInfo = struct {
    free: usize,
    total: usize,
};

const BufferSize = 32;
const MaxProcBufferedFile = kernel.fs.BufferedFile(BufferSize);
pub const MaxProcFile = interface.DeriveFromBase(MaxProcBufferedFile, struct {
    const Self = @This();
    base: MaxProcBufferedFile,

    pub fn create() MaxProcFile {
        var file = MaxProcFile.init(.{
            .base = MaxProcBufferedFile.InstanceType.create("pid_max"),
        });
        _ = file.data().sync();
        return file;
    }
    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create().interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const buffer = &interface.base(self)._buffer;
        const buf = std.fmt.bufPrint(buffer, "{d}\n", .{config.process.max_pid_value}) catch
            buffer;
        interface.base(self)._end = buf.len;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

test "MaxProcFile.ShouldCreateNode" {
    var node = try MaxProcFile.InstanceType.create_node(std.testing.allocator);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("pid_max", node.name());
}

test "MaxProcFile.ShouldSyncAndContainMaxPid" {
    var sut = try MaxProcFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    const result = sut.interface.sync();
    try std.testing.expectEqual(@as(i32, 0), result);

    var buffer: [64]u8 = undefined;
    const readed = sut.interface.read(&buffer);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{d}\n", .{config.process.max_pid_value});
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, buffer[0..@intCast(readed)]);
}
