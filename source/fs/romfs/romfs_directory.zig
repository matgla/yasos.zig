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

const kernel = @import("kernel");
const interface = @import("interface");

const FileHeader = @import("file_header.zig").FileHeader;
const RomFsDirectoryIterator = @import("romfs_directory_iterator.zig").RomFsDirectoryIterator;

pub const RomFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _header: FileHeader,

    pub fn create(allocator: std.mem.Allocator, header: FileHeader) RomFsDirectory {
        return RomFsDirectory.init(.{
            ._allocator = allocator,
            ._header = header,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, header: FileHeader) anyerror!kernel.fs.Node {
        const dir = try create(allocator, header).interface.new(allocator);
        return kernel.fs.Node.create_directory(dir);
    }

    pub fn get(self: *Self, dirname: []const u8, node: *kernel.fs.Node) anyerror!void {
        _ = node;
        _ = self;
        _ = dirname;
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        return try (RomFsDirectoryIterator.InstanceType.create(self._header.dupe())).interface.new(self._allocator);
    }

    pub fn name(self: *const Self) []const u8 {
        return self._header.name();
    }

    pub fn close(self: *Self) void {
        _ = self;
    }

    pub fn delete(self: *Self) void {
        self._header.deinit();
    }
});
