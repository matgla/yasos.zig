//
// system_call.zig
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

const c = @cImport({
    @cInclude("kernel/syscalls.h");
});

const process_manager = @import("../process_manager.zig");
const Semaphore = @import("../semaphore.zig").Semaphore;
const KernelSemaphore = @import("kernel_semaphore.zig").KernelSemaphore;
const config = @import("config");

extern fn switch_to_next_task() void;
extern fn store_and_switch_to_next_task() void;

pub const CreateProcessCall = struct {
    allocator: std.mem.Allocator,
    entry: *const anyopaque,
    stack_size: u32,
    arg: ?*const anyopaque,
};

pub const SemaphoreEvent = struct {
    object: *Semaphore,
};

export fn irq_svcall(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) void {
    // those operations must be secure since both cores may be executing that code in the same time
    hal.hw_atomic.lock(config.process.hw_spinlock_number);
    defer hal.hw_atomic.unlock(config.process.hw_spinlock_number);
    switch (number) {
        c.sys_start_root_process => {
            switch_to_next_task();
        },
        c.sys_create_process => {
            const context: *const volatile CreateProcessCall = @ptrCast(@alignCast(arg));
            const result: *volatile bool = @ptrCast(out);
            process_manager.instance.create_process(context.allocator, context.stack_size, context.entry, context.arg) catch {
                return;
            };
            result.* = true;
        },

        .semaphore_acquire => {
            const context: *const volatile SemaphoreEvent = @ptrCast(@alignCast(arg));
            const result: *volatile bool = @ptrCast(@alignCast(out));
            result.* = KernelSemaphore.acquire(context.object);
        },
        .semaphore_release => {
            const context: *const volatile SemaphoreEvent = @ptrCast(@alignCast(arg));
            KernelSemaphore.release(context.object);
        },
        else => {},
    }
}

export fn unlock_pendsv_spinlock() void {
    hal.hw_atomic.unlock(config.process.hw_spinlock_number);
}

export fn irq_pendsv() void {
    hal.hw_atomic.lock(config.process.hw_spinlock_number);
    store_and_switch_to_next_task();
}

pub fn trigger(number: c.SystemCall, arg: ?*const anyopaque, out: ?*anyopaque) void {
    var svc_arg: *const anyopaque = undefined;
    var svc_out: *anyopaque = undefined;

    if (arg) |a| {
        svc_arg = a;
    }
    if (out) |o| {
        svc_out = o;
    }

    hal.irq.trigger_supervisor_call(number, svc_arg, svc_out);
}
