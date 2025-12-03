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
const std = @import("std");
const config = @import("config");

const hal = @import("hal");
const arch = @import("arch");

const process_manager = @import("../process_manager.zig");

var tick_counter: u64 = 0;
var last_time: u64 = 0;

pub export fn irq_systick() void {
    const state = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(state);

    const tick_counter_ptr: *volatile u64 = &tick_counter;
    tick_counter_ptr.* += 1;
    if (tick_counter_ptr.* - last_time >= 100) { //config.process.context_switch_period) {
        hal.irq.trigger(.pendsv);
        last_time = tick_counter_ptr.*;
    }
}

pub fn get_system_ticks() *const volatile u64 {
    const ptr: *const volatile u64 = &tick_counter;
    return ptr;
}

// Test helpers for resetting state
fn reset_systick_state() void {
    tick_counter = 0;
    last_time = 0;
}

// test "Systick.GetSystemTicks.ShouldReturnInitialZero" {
//     reset_systick_state();
//     const ticks = get_system_ticks();
//     try std.testing.expectEqual(@as(u64, 0), ticks.*);
// }

// test "Systick.IrqSystick.ShouldIncrementTickCounter" {
//     reset_systick_state();

//     const ticks = get_system_ticks();
//     try std.testing.expectEqual(@as(u64, 0), ticks.*);

//     irq_systick();
//     try std.testing.expectEqual(@as(u64, 1), ticks.*);

//     irq_systick();
//     try std.testing.expectEqual(@as(u64, 2), ticks.*);

//     irq_systick();
//     try std.testing.expectEqual(@as(u64, 3), ticks.*);

//     reset_systick_state();
// }

// test "Systick.IrqSystick.ShouldIncrementMultipleTimes" {
//     reset_systick_state();

//     const ticks = get_system_ticks();
//     const expected_ticks: u64 = 100;

//     var i: u64 = 0;
//     while (i < expected_ticks) : (i += 1) {
//         irq_systick();
//     }

//     try std.testing.expectEqual(expected_ticks, ticks.*);

//     reset_systick_state();
// }

// var call_count: usize = 0;
// test "Systick.IrqSystick.ShouldTriggerContextSwitch" {
//     reset_systick_state();

//     // Simulate ticks until context switch
//     const switch_period = config.process.context_switch_period;

//     const PendSvAction = struct {
//         pub fn call() void {
//             call_count += 1;
//         }
//     };

//     // Tick until just before switch
//     var i: u64 = 0;
//     call_count = 0;
//     hal.irq.impl().set_irq_action(.pendsv, &PendSvAction.call);
//     while (i < switch_period + 10) : (i += 1) {
//         irq_systick();
//     }

//     const ticks = get_system_ticks();
//     try std.testing.expectEqual(switch_period + 10, ticks.*);
//     try std.testing.expectEqual(1, call_count);
// }
