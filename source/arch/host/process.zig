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

pub const Process = struct {};
pub fn prepare_process_stack(
    stack: []u8,
    comptime exit_handler: *const fn () void,
    entry_point: ?*const anyopaque,
    arg: ?*const anyopaque,
) *u8 {
    _ = exit_handler;
    _ = entry_point;
    _ = arg;
    return @ptrCast(stack.ptr);
}

pub fn initialize_context_switching() void {}

pub fn init() void {}
