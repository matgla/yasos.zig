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
const Process = @import("../process.zig").Process;
const Semaphore = @import("../semaphore.zig").Semaphore;

// this is kernel semaphore intended to be used by kernel events handlers
// which means it shouldn't be interrupted since interrupt handlers are blocking

pub const KernelSemaphore = struct {
    // blocking
    pub fn release(semaphore: *Semaphore) i32 {
        semaphore.counter.increment();
        // unblock waiting processes
        var next = process_manager.instance.processes.first;
        while (next) |node| {
            const process: *Process = @fieldParentPtr("node", node);
            next = node.next;
            if (process.is_blocked_by(semaphore)) {
                process.unblock_semaphore(semaphore);
            }
        }
        return 0;
    }

    // blocking
    pub fn acquire(semaphore: *Semaphore) !i32 {
        if (!semaphore.counter.compare_not_equal_decrement(0)) {
            // this must be service call
            const maybe_process = process_manager.instance.get_current_process();
            if (maybe_process) |process| {
                process.block_semaphore(semaphore);
            }
            hal.irq.trigger(.pendsv);
            // process is blocked, let's trigger scheduler
            return 1;
        }
        return 0;
    }
};
