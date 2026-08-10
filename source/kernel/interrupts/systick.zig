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
const xip_stats = @import("../process/xipstat_file.zig");
const kernel_sync = @import("../sync/sync.zig");

/// Milliseconds since boot.
///
/// Two things make this awkward on a second core, and they pull in opposite
/// directions:
///
///   * **SysTick is per-core hardware** (it lives in the SCS), so core 1 gets
///     its own interrupt. A shared counter incremented by both would run at
///     twice wall-clock speed -- and unlike most per-CPU state, a *clock* must
///     not be summed across cores either.
///   * It is 64 bits on a machine with no `LDREXD`, and it is read concurrently
///     by `sleep_for_us` and `sysinfo`. A plain two-halves read can catch the
///     increment mid-carry and land four billion ticks in the future.
///
/// So: exactly one core advances it (`timekeeper_core`), which removes the
/// double count and leaves a single writer; and it is published through a
/// seqlock, which removes the torn read. Readers never hold the tick up.
var ticks: kernel_sync.Seq64 = .init(0);

/// The core that owns wall-clock time. Every other core's SysTick still fires
/// and still drives *its own* preemption, but does not touch the clock.
const timekeeper_core: usize = 0;

/// Tick at which this core last forced a reschedule. Per-CPU: each core
/// preempts on its own schedule, and a shared value would let one core's
/// timeslice reset the other's.
var last_preempt: kernel_sync.PerCpu(u64) = .init(0);

pub export fn irq_systick() void {
    const state = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(state);

    // Drain the XIP cache counters here because they saturate rather than wrap,
    // so the only safe reading interval is one shorter than the time it takes
    // to fill them -- seconds, against this tick's millisecond. Costs a null
    // check on machines that publish no sampler.
    xip_stats.accumulate();

    // Only the timekeeper advances the clock. The read-modify-write is safe
    // without a lock precisely because of that: one writer, and it is this
    // handler, which cannot preempt itself.
    const now = blk: {
        if (kernel_sync.percpu.current_core() == timekeeper_core) {
            const next = ticks.load() +% 1;
            ticks.store(next);
            break :blk next;
        }
        break :blk ticks.load();
    };

    // Preemption is per-core: every core forces its own reschedule on its own
    // timeslice, whether or not it owns the clock.
    const last = last_preempt.current();
    if (now -% last.* >= 100) { //config.process.context_switch_period) {
        hal.irq.trigger(.pendsv);
        last.* = now;
    }
}

/// Milliseconds since boot.
///
/// Returns a value, not a pointer. It used to hand out a `*const volatile u64`
/// that callers dereferenced at their leisure, which is exactly the read the
/// seqlock exists to prevent -- there is no way to retry a raw dereference.
pub fn get_system_ticks() u64 {
    return ticks.load();
}

// Test helpers for resetting state
fn reset_systick_state() void {
    ticks = .init(0);
    last_preempt.current().* = 0;
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
