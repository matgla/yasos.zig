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

const hal = @import("hal");

const process_manager = @import("../process_manager.zig");

var tick_counter: u64 = 0;
const ticks_per_event = 1000;
var last_time: u64 = 0;

export fn irq_systick() void {
    hal.hw_atomic.lock(config.process.context_switch_hw_spinlock_number);
    defer hal.hw_atomic.unlock(config.process.context_switch_hw_spinlock_number);
    // modify from core 0 only
    const tick_counter_ptr: *volatile u64 = &tick_counter;
    tick_counter_ptr.* += 1;
    if (tick_counter_ptr.* - last_time >= config.process.context_switch_period) {
        hal.irq.trigger(.pendsv);
        last_time = tick_counter_ptr.*;
    }
}

pub fn get_system_ticks() u64 {
    hal.hw_atomic.lock(config.process.context_switch_hw_spinlock_number);
    defer hal.hw_atomic.unlock(config.process.context_switch_hw_spinlock_number);
    const ptr: *const volatile u64 = &tick_counter;
    return ptr.*;
}
