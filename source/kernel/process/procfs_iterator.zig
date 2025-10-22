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
            // skip 0
            _ = self._prociter.?.next();
        }

        if (self._prociter) |*it| {
            if (it.next()) |pid| {
                if (self._proc_name) |name| {
                    self._allocator.free(name);
                }
                self._proc_name = std.fmt.allocPrint(self._allocator, "{d}", .{pid}) catch return null;

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
        _ = self;
    }
});
