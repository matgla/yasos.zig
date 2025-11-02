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

// This semaphore implementation is intended to be used by users
// It is just forwarding requests to kernel through system calls

const SemaphoreEvent = @import("interrupts/syscall_handlers.zig").SemaphoreEvent;
const syscall = @import("interrupts/system_call.zig");

const atomic = @import("hal").atomic;

const c = @import("libc_imports").c;

pub const Semaphore = struct {
    max_value: u32,
    counter: atomic.Atomic(u32),

    pub fn create(init: u32) Semaphore {
        return Semaphore{
            .max_value = init,
            .counter = atomic.Atomic(u32).create(init),
        };
    }

    pub fn acquire(self: *Semaphore) void {
        if (self.counter.value > 0) {
            const event = SemaphoreEvent{
                .object = self,
            };
            var result: bool = false;
            while (!result) {
                syscall.trigger(c.sys_semaphore_acquire, &event, &result);
            }
        }
    }

    pub fn release(self: *Semaphore) void {
        if (self.counter.value < self.max_value) {
            const event = SemaphoreEvent{
                .object = self,
            };
            syscall.trigger(c.sys_semaphore_release, &event, null);
        }
    }
};

const std = @import("std");
const hal = @import("hal");
const syscall_handlers = @import("interrupts/syscall_handlers.zig");

test "Semaphore.ShouldAcquireAndRelease" {
    var sut = Semaphore.create(3);
    defer hal.irq.impl().clear();

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
    sut.acquire();
    sut.acquire();
    try std.testing.expectEqual(2, hal.irq.impl().calls[c.sys_semaphore_acquire]);
    try std.testing.expectEqual(1, sut.counter.value);
    try std.testing.expectEqual(0, hal.irq.impl().calls[c.sys_semaphore_release]);
    sut.release();
    try std.testing.expectEqual(1, hal.irq.impl().calls[c.sys_semaphore_release]);
    try std.testing.expectEqual(2, sut.counter.value);

    sut.acquire();
    sut.acquire();
    sut.acquire();
    sut.acquire();
    try std.testing.expectEqual(4, hal.irq.impl().calls[c.sys_semaphore_acquire]);
    try std.testing.expectEqual(0, sut.counter.value);

    sut.release();
    try std.testing.expectEqual(2, hal.irq.impl().calls[c.sys_semaphore_release]);
    try std.testing.expectEqual(1, sut.counter.value);
    sut.release();
    sut.release();
    sut.release();
    sut.release();
    sut.release();
    sut.release();
    try std.testing.expectEqual(4, hal.irq.impl().calls[c.sys_semaphore_release]);
    try std.testing.expectEqual(3, sut.counter.value);
}
