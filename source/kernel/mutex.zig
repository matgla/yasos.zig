//
// mutex.zig
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

const Semaphore = @import("semaphore.zig").Semaphore;
const config = @import("config");

pub const Mutex = struct {
    semaphore: Semaphore = Semaphore.create(1),

    pub fn lock(self: *Mutex) void {
        self.semaphore.acquire();
    }

    pub fn unlock(self: *Mutex) void {
        self.semaphore.release();
    }
};

const hal = @import("hal");
const c = @import("libc_imports").c;
const syscall_handlers = @import("interrupts/syscall_handlers.zig");

test "Mutex.ShouldLock" {
    defer hal.irq.impl().clear();
    var mutex = Mutex{};

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

    try std.testing.expectEqual(0, hal.irq.impl().calls[c.sys_semaphore_acquire]);
    mutex.lock();
    mutex.lock();
    try std.testing.expectEqual(1, hal.irq.impl().calls[c.sys_semaphore_acquire]);
    try std.testing.expectEqual(0, mutex.semaphore.counter.value);
    try std.testing.expectEqual(0, hal.irq.impl().calls[c.sys_semaphore_release]);
    mutex.unlock();
    try std.testing.expectEqual(1, hal.irq.impl().calls[c.sys_semaphore_release]);
    try std.testing.expectEqual(1, mutex.semaphore.counter.value);
}
