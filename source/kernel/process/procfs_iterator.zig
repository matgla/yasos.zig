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

pub const ProcInfo = struct {
    file: kernel.fs.IFile,
    node: std.DoublyLinkedList.Node,
};

pub const ProcFsIterator = struct {
    pub usingnamespace interface.DeriveFromBase(kernel.fs.IDirectoryIterator, ProcFsIterator);
    pub const Self = @This();
    _node: ?*std.DoublyLinkedList.Node,

    pub fn create(first_node: ?*std.DoublyLinkedList.Node) ProcFsIterator {
        return .{
            ._node = first_node,
        };
    }

    pub fn next(self: *Self) ?kernel.fs.IFile {
        if (self._node) |node| {
            self._node = node.*.next;
            const info: *ProcInfo = @fieldParentPtr("node", node);
            return info.file.share();
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
};
