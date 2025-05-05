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

const log = &@import("../log/kernel_log.zig").kernel_log;

pub fn sleep(seconds: u32) void {
    sleep_ms(seconds * 1000);
}

pub fn sleep_ms(ms: u32) void {
    const start = systick.get_system_ticks();
    // 1000 - ticks = 1 ms
    var elapsed: u64 = 0;
    const ptr: *volatile u64 = &elapsed;
    while (ptr.* < ms) {
        ptr.* = systick.get_system_ticks() - start;
        asm volatile (
            \\ wfi
        );
    }
}

pub fn sleep_us(us: u32) void {
    _ = us;
    // const maybe_process = process_manager.instance.current_process;
    // if (maybe_process) |process| {
    //     process.sleep_for_us(us);
    // }
}
