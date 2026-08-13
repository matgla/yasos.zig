// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

// Mirrors arch/arm-m/panic.zig so kernel code (malloc leak-detection traces)
// compiles against the host test build.
pub const max_stack_depth: usize = 16;

pub fn is_valid_stack_ptr(addr: usize) bool {
    // On the host there is no fixed RAM map; any non-null pointer is acceptable.
    return addr != 0;
}

const max_trace_depth: usize = 32;

pub const StackWalker = struct {
    addresses: [max_trace_depth]usize = undefined,
    len: usize = 0,
    index: usize = 0,

    pub fn init(first_address: usize) StackWalker {
        var self: StackWalker = .{};
        const trace = std.debug.captureCurrentStackTrace(
            .{ .first_address = if (first_address != 0) first_address else null },
            &self.addresses,
        );
        self.len = trace.return_addresses.len;
        return self;
    }

    pub fn next(self: *StackWalker) ?usize {
        if (self.index >= self.len) return null;
        defer self.index += 1;
        return self.addresses[self.index];
    }
};

pub fn dump_stack_trace(log: anytype, address: usize) void {
    var walker: StackWalker = .init(address);
    var index: usize = 0;
    while (walker.next()) |return_address| : (index += 1) {
        log.err("  {d: >3}: 0x{X:0>8}", .{ index, if (return_address > 0) return_address - 1 else return_address });
    }
}

pub fn get_stack_trace_depth(address: usize) usize {
    var walker: StackWalker = .init(address);
    var index: usize = 0;
    while (walker.next()) |_| : (index += 1) {}
    return index;
}
