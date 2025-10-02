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

const kernel = @import("kernel");
const interface = @import("interface");

const FileHeader = @import("file_header.zig").FileHeader;

pub const RomFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    _header: FileHeader,

    pub fn create(header: FileHeader) RomFsDirectory {
        return RomFsDirectory.init(.{
            ._header = header,
        });
    }

    pub fn get(self: *Self, name: []const u8) ?*kernel.fs.INode {
        _ = self;
        _ = name;
        return null;
    }

    pub fn close(self: *Self) void {
        _ = self;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
