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
    const ExpectationList = std.ArrayList([]const u8);
    var expected_directories: ExpectationList = undefined;
    pub var did_error: anyerror!void = {};

    pub fn init(allocator: std.mem.Allocator) !void {
        expected_directories = ExpectationList.init(allocator);
    }

    pub fn deinit() !void {
        try std.testing.expectEqual(0, expected_directories.items.len);
        expected_directories.deinit();
    }

    pub fn append(path: []const u8) !void {
        try expected_directories.insert(0, path);
    }

    pub fn size() usize {
        return expected_directories.items.len;
    }

    pub fn traverse_dir(file: *kernel.fs.IFile, _: *anyopaque) bool {
        const name = file.name().get_name();
        did_error catch return false;

        const maybe_expectation = expected_directories.pop();
        if (maybe_expectation) |expectation| {
            did_error = std.testing.expectEqualStrings(expectation, name);
            did_error catch {
                std.debug.print("Expectation not matched, expected: '{s}', found: '{s}'\n", .{ expectation, name });
                return false;
            };
        } else {
            std.debug.print("Expectation not found for: '{s}'\n", .{name});
            return false;
        }
        return true;
    }
};
