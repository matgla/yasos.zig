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

const system_call = @import("../../kernel/system_call.zig");

const process_manager = @import("../../kernel/process_manager.zig");

pub fn root_process(allocator: std.mem.Allocator, entry: anytype, arg: anytype, stack_size: usize) !void {
    try process_manager.instance.create_process(allocator, stack_size, entry, arg);
    if (process_manager.instance.scheduler.schedule_next()) {
        process_manager.instance.initialize_context_switching();
        hal.time.systick.enable();
        system_call.trigger(.start_root_process);
    }

    @panic("Can't initialize root process");
}
