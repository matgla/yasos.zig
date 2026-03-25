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

pub fn dump_stack_trace(log: anytype, address: usize) void {
    var index: usize = 0;
    var stack = std.debug.StackIterator.init(address, @frameAddress());

    while (stack.next()) |return_address| : (index += 1) {
        log.err("  {d: >3}: 0x{X:0>8}", .{ index, if (return_address > 0) return_address - 1 else return_address });
    }
}

pub const max_stack_depth: usize = 16;

pub fn is_valid_stack_ptr(addr: usize) bool {
    // SRAM: 0x20000000 - 0x2005FFFF, PSRAM: 0x11000000 - 0x117FFFFF
    return (addr >= 0x11000000 and addr < 0x11800000) or
        (addr >= 0x20000000 and addr < 0x20060000);
}

pub fn get_stack_trace_depth(address: usize) usize {
    var index: usize = 0;
    var stack = std.debug.StackIterator.init(address, @frameAddress());
    while (index < max_stack_depth) : (index += 1) {
        if (!is_valid_stack_ptr(stack.fp)) break;
        if (stack.next() == null) break;
    }
    return index;
}
