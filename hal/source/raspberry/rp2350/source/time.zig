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

const std = @import("std");

const log = std.log.scoped(.@"hal/time");

const picosdk = @import("picosdk.zig").picosdk;

const core = @import("cortex-m");

pub const Time = struct {
    pub const SysTick = core.SysTick;
    var is_initialized: bool = false;
    var fired: bool = false;
    var firedptr: *volatile bool = @ptrCast(&fired);

    // Every read of the timer goes through a pointer derived from a *volatile
    // struct pointer, never through `picosdk.timer0_hw.*.field` directly. The
    // direct form does not reliably keep its volatile-ness in this compiler,
    // and the register it drops it on is a free-running counter: a folded or
    // hoisted load turns a delay into a no-op. That is not theoretical here --
    // it is why the card stopped initialising the moment the HAL was built
    // optimised. ACMD41 is polled with sleep_ms(10) between attempts, and with
    // the delay gone all 1000 retries completed before the card had finished
    // powering up. CMD8, which needs no delay, kept working throughout, which
    // is what made it look like a response-decoding fault.
    // Same shape as the UART driver's `derived_ptr` idiom (source/uart.zig).
    const timer: *volatile picosdk.timer_hw_t = @ptrFromInt(picosdk.TIMER0_BASE);

    pub fn sleep_ms(ms: u64) void {
        var left = ms;
        while (left > 0) {
            sleep_us(1000);
            left -= 1;
        }
    }

    pub fn sleep_us(us: u64) void {
        const raw_low = &timer.*.timerawl;
        const start = raw_low.*;
        // Deliberately 32-bit throughout. timerawl is a 32-bit microsecond
        // counter, so `now - start` wraps correctly on rollover; the previous
        // version compared a 32-bit read against a 64-bit target and would spin
        // for over an hour if a delay straddled the wrap.
        const wait: u32 = if (us > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(us);
        while (raw_low.* -% start < wait) {}
    }

    pub fn get_time_us() u64 {
        const raw_high = &timer.*.timerawh;
        const raw_low = &timer.*.timerawl;
        // timerawl rolls over independently of timerawh, so a naive
        // high-then-low pair can straddle a rollover and report a time an hour
        // out. Re-read the high word and retry when it moved.
        while (true) {
            const high = raw_high.*;
            const low = raw_low.*;
            if (raw_high.* == high) {
                return (@as(u64, high) << 32) | low;
            }
        }
    }

    fn init() void {}
};
