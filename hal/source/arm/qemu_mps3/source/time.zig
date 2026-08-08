//
// time.zig
//
// Wall-clock for the MPS2-AN505 backed by the CMSDK APB Timer0 (a free-running
// 32-bit down-counter at the system clock). Provides microsecond timing
// independent of the scheduler SysTick.
//
// CMSDK APB timer register map (offsets from the timer base):
//   0x00 CTRL   (b0: ENABLE, b1: SELEXTEN, b2: SELEXTCLK, b3: IRQEN)
//   0x04 VALUE  (current down-counter value)
//   0x08 RELOAD
//   0x0C INTSTATUS / INTCLEAR
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

const core = @import("cortex-m");

// SYSCLK on QEMU's MPS2-AN505 is 25 MHz → 25 timer ticks per microsecond.
const ticks_per_us: u64 = 25;

const TIMER_BASE: usize = 0x40000000;
const TIMER_CTRL: *volatile u32 = @ptrFromInt(TIMER_BASE + 0x00);
const TIMER_VALUE: *volatile u32 = @ptrFromInt(TIMER_BASE + 0x04);
const TIMER_RELOAD: *volatile u32 = @ptrFromInt(TIMER_BASE + 0x08);

const CTRL_ENABLE: u32 = 1 << 0;

pub const Time = struct {
    pub const SysTick = core.SysTick;

    var initialized: bool = false;
    var accumulated_ticks: u64 = 0;
    var last_raw: u32 = 0;

    fn ensure_started() void {
        if (initialized) return;
        TIMER_RELOAD.* = 0xFFFF_FFFF;
        TIMER_VALUE.* = 0xFFFF_FFFF;
        TIMER_CTRL.* = CTRL_ENABLE;
        last_raw = up_counter();
        initialized = true;
    }

    // Convert the down-counter into a monotonically increasing 32-bit value.
    fn up_counter() u32 {
        return 0xFFFF_FFFF -% TIMER_VALUE.*;
    }

    // Monotonic tick count, tracking 32-bit wraps across calls.
    fn now_ticks() u64 {
        ensure_started();
        const raw = up_counter();
        const delta = raw -% last_raw;
        accumulated_ticks +%= delta;
        last_raw = raw;
        return accumulated_ticks;
    }

    pub fn get_time_us() u64 {
        return now_ticks() / ticks_per_us;
    }

    pub fn sleep_us(us: u64) void {
        ensure_started();
        const target = get_time_us() + us;
        while (get_time_us() < target) {}
    }

    pub fn sleep_ms(ms: u64) void {
        sleep_us(ms * 1000);
    }
};
