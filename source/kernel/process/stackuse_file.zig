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

// `/proc/stackuse` -- how deep each program's stack really went: for every
// executable, the most it used at any exit and the size it was given.  The depth
// is where the zeroes end, so a measuring build must also clear each stack it
// allocates (the allocator fills them with 0xAA in safe modes), in
// ArmProcess.reallocate_stack.  pid 1 never exits, and vfork children run on its
// stack: watch that one with rp2350_timing's watch= instead.
//
// Off by default: the table is kernel memory and the scan runs at every exit.

const std = @import("std");
const vfmt = @import("../vfmt.zig");

const interface = @import("interface");

const kernel = @import("../kernel.zig");

pub const enabled = false;

const Entry = struct {
    name: [40]u8 = @splat(0),
    max_used: u32 = 0,
    size: u32 = 0,
    exits: u32 = 0,
};
var table: [96]Entry = @splat(.{});

pub fn record(path: []const u8, stack: []const u8) void {
    var free: usize = 0;
    while (free + 4 < stack.len and stack[4 + free] == 0) free += 1;
    const used: u32 = @intCast(stack.len - 4 - free);
    const name = path[path.len - @min(path.len, 39)..];
    for (&table) |*e| {
        if (e.exits != 0 and !std.mem.eql(u8, std.mem.sliceTo(&e.name, 0), name)) continue;
        if (e.exits == 0) @memcpy(e.name[0..name.len], name);
        e.exits += 1;
        e.max_used = @max(e.max_used, used);
        e.size = @intCast(stack.len);
        return;
    }
}

const BufferSize = 4096;
const StackUseBufferedFile = kernel.fs.BufferedFile(BufferSize);

pub const StackUseFile = interface.DeriveFromBase(StackUseBufferedFile, struct {
    const Self = @This();
    base: StackUseBufferedFile,

    pub fn create(allocator: std.mem.Allocator) StackUseFile {
        return StackUseFile.init(.{
            .base = StackUseBufferedFile.InstanceType.create(allocator, "stackuse"),
        });
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create(allocator).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const buffer = interface.base(self).buffer() orelse return -1;
        var written: usize = 0;
        for (&table) |*e| {
            if (e.exits == 0) continue;
            written += vfmt.print(buffer[written..], "{s} {d} {d} {d}\n", .{ std.mem.sliceTo(&e.name, 0), e.max_used, e.size, e.exits }).len;
        }
        interface.base(self)._end = written;
        return 0;
    }

    pub fn delete(self: *Self) void {
        interface.base(self).delete();
    }
});
