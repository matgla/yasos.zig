//
// spawn.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//

const std = @import("std");
const hal = @import("hal").hal;

pub fn root_process(allocator: std.mem.Allocator, entry: anytype, arg: anytype, stack_size: usize, manager: anytype) !void {
    // disable systick when implemented
    // add process
    // schedule
    // start context switching
    // syscall start root
    hal.time.systick.disable();
    defer hal.time.systick.enable();
    try manager.create_process(allocator, stack_size, entry, arg);
}
