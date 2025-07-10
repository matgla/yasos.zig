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
    var stack = std.debug.StackIterator.init(address, null);
    while (stack.next()) |return_address| : (index += 1) {
        log.err("  {d: >3}: 0x{X:0>8}", .{ index, return_address - 1 });
    }
}
