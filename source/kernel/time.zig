//
// time.zig
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

const systick = @import("interrupts/systick.zig");
const process_manager = @import("process_manager.zig");

const kernel = @import("kernel.zig");
const log = kernel.log;

pub fn sleep_ms(ms: u32) void {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process.sleep_for_ms(ms);
    }
}

pub fn sleep_us(us: u32) void {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process.sleep_for_us(us);
    }
}

const std = @import("std");
const hal = @import("hal");
const irq_systick = @import("interrupts/systick.zig").irq_systick;
const irq_handlers = @import("arch").irq_handlers;
const system_call = @import("interrupts/system_call.zig");

fn test_entry() void {}

var call_count: usize = 0;

test "Time.ProcessShoulSleep" {
    kernel.process.process_manager.initialize_process_manager(std.testing.allocator);
    defer kernel.process.process_manager.deinitialize_process_manager();
    defer hal.irq.impl().clear();

    var arg: usize = 0;
    try kernel.process.process_manager.instance.create_process(1024, &test_entry, &arg, "test");
    try kernel.process.process_manager.instance.create_process(1024, &test_entry, &arg, "test2");
    _ = kernel.process.process_manager.instance.schedule_next();
    _ = kernel.process.process_manager.get_next_task();
    system_call.init(std.testing.allocator);

    hal.time.impl.set_time(0);

    const PendSvAction = struct {
        pub fn call() void {
            hal.time.systick.set_ticks(hal.time.systick.get_system_tick() + 1000);
            for (0..1000) |_| irq_systick();
            _ = irq_handlers.call_context_switch_handler(0);
            call_count += 1;
        }
    };

    hal.irq.impl().set_irq_action(.pendsv, &PendSvAction.call);

    call_count = 0;
    sleep_ms(400);
    try std.testing.expectEqual(1, call_count);
}
