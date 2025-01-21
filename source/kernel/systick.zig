//
// systick.zig
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

const config = @import("config");
const process_manager = @import("process_manager.zig");
const hal = @import("hal");

var tick_counter: u64 = 0;
const ticks_per_event = 1000;
var last_time: u64 = 0;

export fn irq_systick() void {
    const tick_counter_ptr: *volatile u64 = &tick_counter;
    tick_counter_ptr.* += ticks_per_event;
    if (tick_counter_ptr.* - last_time >= config.process.context_switch_period * ticks_per_event) {
        if (process_manager.instance.scheduler.schedule_next()) {
            hal.irq.trigger(.pendsv);
        }
        last_time = tick_counter_ptr.*;
    }
}
