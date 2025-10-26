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

pub const TestDirectoryTraverser = struct {
    const ExpectationList = std.ArrayList(kernel.fs.DirectoryEntry);
    _expected_directories: ExpectationList,
    _dir: kernel.fs.Node,

    pub fn create(allocator: std.mem.Allocator, dir: kernel.fs.Node) !TestDirectoryTraverser {
        return .{
            ._expected_directories = try ExpectationList.initCapacity(allocator, 0),
            ._dir = dir,
        };
    }

    pub fn deinit(self: *TestDirectoryTraverser) void {
        self._expected_directories.deinit(std.testing.allocator);
        self._dir.delete();
    }

    pub fn append(self: *TestDirectoryTraverser, expectation: kernel.fs.DirectoryEntry) !void {
        try self._expected_directories.insert(std.testing.allocator, 0, expectation);
    }

    pub fn appendSlice(self: *TestDirectoryTraverser, expectations: []const kernel.fs.DirectoryEntry) !void {
        for (expectations) |expectation| {
            try self.append(expectation);
        }
    }

    pub fn verify(self: *TestDirectoryTraverser) !void {
        try self.traverse();
        if (self._expected_directories.items.len != 0) {
            return error.MissingExpectedEntries;
        }
    }

    fn traverse(self: *TestDirectoryTraverser) !void {
        var maybe_dir = self._dir.as_directory();
        if (maybe_dir) |*dir| {
            var it = try dir.interface.iterator();
            defer it.interface.delete();
            while (it.interface.next()) |file| {
                try self.verify_file(file);
            }
            return;
        }
        return error.NotADirectory;
    }

    fn verify_file(self: *TestDirectoryTraverser, file: kernel.fs.DirectoryEntry) !void {
        for (self._expected_directories.items, 0..) |expect, i| {
            if (std.mem.eql(u8, file.name, expect.name) and file.kind == expect.kind) {
                _ = self._expected_directories.orderedRemove(i);
                return;
            }
        }
        std.debug.print("Unexpected file found: {s} with type: {s}\n", .{ file.name, @tagName(file.kind) });
        try std.testing.expect(false);
    }
};

pub fn verify_directory_content(sut: *kernel.fs.IFileSystem, path: []const u8, expected: []const kernel.fs.DirectoryEntry) !void {
    var maybe_node = sut.interface.get(path, std.testing.allocator);
    if (maybe_node) |*node| {
        try std.testing.expect(node.is_directory());
        if (node.filetype() != .Directory) {
            node.delete();
        }
        var dirit = try TestDirectoryTraverser.create(std.testing.allocator, node.*);
        defer dirit.deinit();
        try dirit.appendSlice(expected);
        try dirit.verify();
        return;
    }
    return error.NodeNotFound;
}
