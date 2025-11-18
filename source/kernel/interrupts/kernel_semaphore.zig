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
            const process: *Process = @alignCast(@fieldParentPtr("node", node));
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
            const process = process_manager.instance.get_current_process();
            process.block_semaphore(semaphore);
            hal.irq.trigger(.pendsv);
            // process is blocked, let's trigger scheduler
            return 1;
        }
        return 0;
    }
};

const kernel = @import("../kernel.zig");
const irq_systick = @import("systick.zig").irq_systick;
const c = @import("libc_imports").c;
const syscall_handlers = @import("syscall_handlers.zig");

fn test_entry() void {}

var call_count: usize = 0;

test "KernelSemaphore.ShouldBlockProcess" {
    kernel.process.process_manager.initialize_process_manager(std.testing.allocator);
    defer kernel.process.process_manager.deinitialize_process_manager();
    defer hal.irq.impl().clear();

    var proc_arg: usize = 0;
    try kernel.process.process_manager.instance.create_process(1024, &test_entry, &proc_arg, "test");
    try kernel.process.process_manager.instance.create_process(1024, &test_entry, &proc_arg, "test2");
    _ = kernel.process.process_manager.instance.schedule_next();
    _ = kernel.process.process_manager.process_set_next_task();

    const ActionCall = struct {
        pub fn acquire(id: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) callconv(.c) void {
            const event: *const volatile syscall_handlers.SemaphoreEvent = @ptrCast(@alignCast(arg));
            event.object.counter.value -= 1;
            hal.irq.impl().calls[id] += 1;
            const result: *volatile bool = @ptrCast(@alignCast(out));
            result.* = true;
        }

        pub fn release(id: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) callconv(.c) void {
            const event: *const volatile syscall_handlers.SemaphoreEvent = @ptrCast(@alignCast(arg));
            event.object.counter.value += 1;
            hal.irq.impl().calls[id] += 1;
            const result: *volatile bool = @ptrCast(@alignCast(out));
            result.* = true;
        }
    };

    hal.irq.impl().set_action(c.sys_semaphore_acquire, &ActionCall.acquire);
    hal.irq.impl().set_action(c.sys_semaphore_release, &ActionCall.release);

    var semaphore = Semaphore.create(1);
    semaphore.acquire();

    const PendSvAction = struct {
        pub fn call() void {
            hal.time.systick.set_ticks(hal.time.systick.get_system_tick() + 1000);
            for (0..1000) |_| irq_systick();
            call_count += 1;
        }
    };

    hal.irq.impl().set_irq_action(.pendsv, &PendSvAction.call);
    try std.testing.expectEqual(1, try KernelSemaphore.acquire(&semaphore));
    try std.testing.expectEqual(0, semaphore.counter.value);
    try std.testing.expectEqual(1, call_count);
    const process = kernel.process.process_manager.instance.get_current_process();
    try std.testing.expectEqual(Process.State.Blocked, process.state);
    process.reevaluate_state();
    try std.testing.expectEqual(Process.State.Blocked, process.state);
    try std.testing.expectEqual(0, KernelSemaphore.release(&semaphore));
    try std.testing.expectEqual(1, semaphore.counter.value);
    process.reevaluate_state();
    try std.testing.expectEqual(Process.State.Ready, process.state);
}
