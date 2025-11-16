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

const c = @import("libc_imports").c;

pub fn root_process(entry: anytype, arg: ?*const anyopaque, stack_size: u32) !void {
    try process_manager.instance.create_process(stack_size, entry, arg, "/");

    if (process_manager.instance.schedule_next() != .NoAction) {
        process_manager.instance.initialize_context_switching();
        hal.time.systick.enable();
        system_call.trigger(c.sys_start_root_process, arg, null);
    }
}

pub fn idle_process(entry: anytype, arg: ?*const anyopaque, stack_size: u32) !void {
    try process_manager.instance.create_idle_process(stack_size, entry, arg, "/");
}

const kernel = @import("kernel.zig");
const arch_process = &@import("arch").process;

fn test_main() void {}

test "Spawn.ShouldStartRootProcess" {
    kernel.process.process_manager.initialize_process_manager(std.testing.allocator);
    defer kernel.process.process_manager.deinitialize_process_manager();
    try root_process(&test_main, null, 0x4000);
    try std.testing.expectEqual(true, arch_process.context_switch_initialized);
    try std.testing.expectEqual(1, hal.irq.impl().calls[c.sys_start_root_process]);
}
