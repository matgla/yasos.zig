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

const kernel = @import("kernel");
const IDirectoryIterator = kernel.fs.IDirectoryIterator;
const IFile = kernel.fs.IFile;
const FileHeader = @import("file_header.zig").FileHeader;
const RomFsFile = @import("romfs_file.zig").RomFsFile;

pub const RomFsDirectoryIterator = interface.DeriveFromBase(IDirectoryIterator, struct {
    pub const Self = @This();
    _file: ?FileHeader,
    _allocator: std.mem.Allocator,

    pub fn create(first_file: ?FileHeader, allocator: std.mem.Allocator) RomFsDirectoryIterator {
        return RomFsDirectoryIterator.init(.{
            ._file = first_file,
            ._allocator = allocator,
        });
    }

    pub fn next(self: *Self) ?IFile {
        if (self._file) |*file| {
            const ifile: IFile = RomFsFile.InstanceType.create(file.*, self._allocator).interface.new(self._allocator) catch {
                return null;
            };
            self._file = file.next();
            return ifile;
        }
        return null; // End of iteration
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
