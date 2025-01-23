//
// semaphore.zig
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

const process_manager = @import("../process_manager.zig");
const Semaphore = @import("../semaphore.zig").Semaphore;

// this is kernel semaphore intended to be used by kernel events handlers
// which means it shouldn't be interrupted since interrupt handlers are blocking
extern fn store_and_switch_to_next_task() void;

pub const KernelSemaphore = struct {
    // blocking
    pub fn release(semaphore: *Semaphore) void {
        semaphore.counter.increment();
        // unblock waiting processes
        var it = process_manager.instance.processes.first;
        while (it) |node| : (it = node.next) {
            if (node.data.is_blocked_by(semaphore)) {
                node.data.unblock();
            }
        }
    }

    // blocking
    pub fn acquire(semaphore: *Semaphore) bool {
        if (!semaphore.counter.compare_not_equal_decrement(0)) {
            // this must be service call
            const maybe_process = process_manager.instance.get_current_process();
            if (maybe_process) |process| {
                process.block(semaphore);
            }
            if (process_manager.instance.scheduler.schedule_next()) {
                hal.irq.trigger(.pendsv);
            }
            // process is blocked, let's trigger scheduler
            return false;
        }
        return true;
    }
};
