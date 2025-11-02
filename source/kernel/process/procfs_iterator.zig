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

pub const ProcFsIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    pub const Self = @This();
    const PidMap = @TypeOf(kernel.process.process_manager.instance).PidMap;
    _allocator: std.mem.Allocator,
    _items: []kernel.fs.Node,
    _index: usize,
    _pidmap: ?PidMap,
    _prociter: ?@TypeOf(kernel.process.process_manager.instance).PidIterator,
    _proc_name: ?[]const u8,

    pub fn create(allocator: std.mem.Allocator, items: []kernel.fs.Node, pidmap: ?PidMap) ProcFsIterator {
        return ProcFsIterator.init(.{
            ._allocator = allocator,
            ._items = items,
            ._index = 0,
            ._pidmap = pidmap,
            ._prociter = null,
            ._proc_name = null,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.DirectoryEntry {
        if (self._prociter == null and self._pidmap != null) {
            self._prociter = self._pidmap.?.iterator(.{
                .kind = .unset,
            });
        }

        if (self._prociter) |*it| {
            if (it.next()) |pid| {
                if (self._proc_name) |name| {
                    self._allocator.free(name);
                }
                self._proc_name = std.fmt.allocPrint(self._allocator, "{d}", .{pid + 1}) catch return null;

                return .{
                    .name = self._proc_name.?,
                    .kind = .Directory,
                };
            }
        }
        if (self._proc_name) |name| {
            self._allocator.free(name);
            self._proc_name = null;
        }
        if (self._index < self._items.len) {
            const node = self._items[self._index];
            self._index += 1;
            return .{
                .name = node.name(),
                .kind = node.filetype(),
            };
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        if (self._proc_name) |name| {
            self._allocator.free(name);
            self._proc_name = null;
        }
    }
});

const FileMock = @import("../fs/tests/file_mock.zig").FileMock;
const DirectoryMock = @import("../fs/tests/directory_mock.zig").DirectoryMock;

test "ProcFsIterator.ShouldIterateEmptyList" {
    var items = [_]kernel.fs.Node{};
    var iterator = try ProcFsIterator.InstanceType.create(std.testing.allocator, &items, null).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), iterator.interface.next());
}

test "ProcFsIterator.ShouldIterateSingleFile" {
    var file_mock = try FileMock.create(std.testing.allocator);
    defer file_mock.delete();

    _ = file_mock
        .expectCall("name")
        .willReturn("testfile");

    _ = file_mock
        .expectCall("filetype")
        .willReturn(kernel.fs.FileType.File);

    var node = kernel.fs.Node.create_file(file_mock.get_interface());
    defer node.delete();
    var items = [_]kernel.fs.Node{node};

    var iterator = try ProcFsIterator.InstanceType.create(std.testing.allocator, &items, null).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    const entry = iterator.interface.next();
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("testfile", entry.?.name);
    try std.testing.expectEqual(kernel.fs.FileType.File, entry.?.kind);

    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), iterator.interface.next());
}

test "ProcFsIterator.ShouldIterateMultipleNodes" {
    var file_mock1 = try FileMock.create(std.testing.allocator);

    _ = file_mock1
        .expectCall("name")
        .willReturn("file1");

    _ = file_mock1
        .expectCall("filetype")
        .willReturn(kernel.fs.FileType.File);

    var file_mock2 = try FileMock.create(std.testing.allocator);

    _ = file_mock2
        .expectCall("name")
        .willReturn("file2");

    _ = file_mock2
        .expectCall("filetype")
        .willReturn(kernel.fs.FileType.File);

    var node1 = kernel.fs.Node.create_file(file_mock1.get_interface());
    var node2 = kernel.fs.Node.create_file(file_mock2.get_interface());
    defer {
        node1.delete();
        node2.delete();
    }
    var items = [_]kernel.fs.Node{ node1, node2 };

    var iterator = try ProcFsIterator.InstanceType.create(std.testing.allocator, &items, null).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    const entry1 = iterator.interface.next();
    try std.testing.expect(entry1 != null);
    try std.testing.expectEqualStrings("file1", entry1.?.name);

    const entry2 = iterator.interface.next();
    try std.testing.expect(entry2 != null);
    try std.testing.expectEqualStrings("file2", entry2.?.name);

    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), iterator.interface.next());
}

test "ProcFsIterator.ShouldIterateWithDirectories" {
    var dir_mock = try DirectoryMock.create(std.testing.allocator);
    defer dir_mock.delete();

    _ = dir_mock
        .expectCall("name")
        .willReturn("testdir");

    const node = kernel.fs.Node.create_directory(dir_mock.get_interface());
    var items = [_]kernel.fs.Node{node};
    defer items[0].delete();

    var iterator = try ProcFsIterator.InstanceType.create(std.testing.allocator, &items, null).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    const entry = iterator.interface.next();
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("testdir", entry.?.name);
    try std.testing.expectEqual(kernel.fs.FileType.Directory, entry.?.kind);

    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), iterator.interface.next());
}

fn test_entry() void {}
test "ProcFsIterator.ShouldIterateWithPidMap" {
    kernel.process.process_manager.initialize_process_manager(std.testing.allocator);
    defer kernel.process.process_manager.deinitialize_process_manager();

    // Create some processes
    var arg: usize = 0;
    try kernel.process.process_manager.instance.create_process(4096, &test_entry, &arg, "test");
    try kernel.process.process_manager.instance.create_process(4096, &test_entry, &arg, "test2");

    var items = [_]kernel.fs.Node{};
    var iterator = try ProcFsIterator.InstanceType.create(std.testing.allocator, &items, kernel.process.process_manager.instance.get_pidmap()).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    // Should iterate through PIDs first
    const entry1 = iterator.interface.next();
    try std.testing.expect(entry1 != null);
    try std.testing.expectEqual(kernel.fs.FileType.Directory, entry1.?.kind);

    const entry2 = iterator.interface.next();
    try std.testing.expect(entry2 != null);
    try std.testing.expectEqual(kernel.fs.FileType.Directory, entry2.?.kind);

    // Should return null after all PIDs
    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), iterator.interface.next());
}

test "ProcFsIterator.ShouldIteratePidsAndNodes" {
    kernel.process.process_manager.initialize_process_manager(std.testing.allocator);
    defer kernel.process.process_manager.deinitialize_process_manager();

    // Create a process
    var arg: usize = 0;
    try kernel.process.process_manager.instance.create_process(4096, &test_entry, &arg, "test");

    var file_mock = try FileMock.create(std.testing.allocator);
    defer file_mock.delete();

    _ = file_mock
        .expectCall("name")
        .willReturn("meminfo");

    _ = file_mock
        .expectCall("filetype")
        .willReturn(kernel.fs.FileType.File);

    const node = kernel.fs.Node.create_file(file_mock.get_interface());
    var items = [_]kernel.fs.Node{node};
    defer items[0].delete();

    var iterator = try ProcFsIterator.InstanceType.create(std.testing.allocator, &items, kernel.process.process_manager.instance.get_pidmap()).interface.new(std.testing.allocator);
    defer iterator.interface.delete();

    // First should be the PID
    const entry1 = iterator.interface.next();
    try std.testing.expect(entry1 != null);
    try std.testing.expectEqual(kernel.fs.FileType.Directory, entry1.?.kind);

    // Then the file node
    const entry2 = iterator.interface.next();
    try std.testing.expect(entry2 != null);
    try std.testing.expectEqualStrings("meminfo", entry2.?.name);
    try std.testing.expectEqual(kernel.fs.FileType.File, entry2.?.kind);

    try std.testing.expectEqual(@as(?kernel.fs.DirectoryEntry, null), iterator.interface.next());
}
