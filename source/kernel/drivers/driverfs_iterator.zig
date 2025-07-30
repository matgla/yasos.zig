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

const kernel = @import("../kernel.zig");

const interface = @import("interface");

const IDirectoryIterator = kernel.fs.IDirectoryIterator;

pub const DriverFsIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    pub const Self = @This();
    pub const IteratorType = std.StringHashMap(kernel.driver.IDriver).Iterator;

    _iterator: IteratorType,
    _allocator: std.mem.Allocator,

    pub fn create(iterator: IteratorType, allocator: std.mem.Allocator) DriverFsIterator {
        return DriverFsIterator.init(.{
            ._iterator = iterator,
            ._allocator = allocator,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.IFile {
        if (self._iterator.next()) |driver| {
            return driver.value_ptr.interface.ifile(self._allocator);
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
