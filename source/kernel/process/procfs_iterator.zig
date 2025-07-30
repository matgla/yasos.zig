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

const interface = @import("interface");
const kernel = @import("../kernel.zig");

const MemInfoFile = @import("meminfo_file.zig").MemInfoFile;

pub const ProcInfoType = enum {
    meminfo,
};

pub const ProcInfo = struct {
    infotype: ProcInfoType,
    node: std.DoublyLinkedList.Node,
};

pub const ProcFsIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    pub const Self = @This();
    _node: ?*std.DoublyLinkedList.Node,
    _allocator: std.mem.Allocator,

    pub fn create(first_node: ?*std.DoublyLinkedList.Node, allocator: std.mem.Allocator) ProcFsIterator {
        return ProcFsIterator.init(.{
            ._node = first_node,
            ._allocator = allocator,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.IFile {
        if (self._node) |node| {
            self._node = node.*.next;
            const info: *ProcInfo = @fieldParentPtr("node", node);
            switch (info.infotype) {
                .meminfo => return (MemInfoFile.InstanceType.create()).interface.new(self._allocator) catch return null,
            }
            return null;
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
