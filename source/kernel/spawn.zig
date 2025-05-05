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
const hal = @import("hal");

const system_call = @import("interrupts/system_call.zig");

const process_manager = @import("process_manager.zig");

const c = @import("../libc_imports.zig").c;

pub fn spawn(allocator: std.mem.Allocator, entry: anytype, arg: ?*const anyopaque, stack_size: u32) error{ProcessCreationFailed}!void {
    const context = system_call.CreateProcessCall{
        .allocator = allocator,
        .entry = @ptrCast(entry),
        .stack_size = stack_size,
        .arg = arg,
    };

    var result: bool = false;
    system_call.trigger(.create_process, &context, &result);
    if (!result) {
        return error.ProcessCreationFailed;
    }
}

pub fn root_process(entry: anytype, arg: ?*const anyopaque, stack_size: usize) !void {
    try process_manager.instance.create_process(stack_size, entry, arg, "/");
    if (process_manager.instance.scheduler.schedule_next()) {
        process_manager.instance.initialize_context_switching();
        hal.time.systick.enable();
        system_call.trigger(c.sys_start_root_process, arg, null);
    }

    @panic("Can't initialize root process");
}
