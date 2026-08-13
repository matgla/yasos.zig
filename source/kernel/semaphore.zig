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

const c = @import("libc_imports").c;

pub const Semaphore = struct {
    max_value: u32,
    /// Plain, not an atomic: a `Semaphore` is a userspace object living in the
    /// process heap, whose tier 1 is PSRAM, which is outside the global
    /// exclusive monitor -- an atomic here would appear to work and guarantee
    /// nothing across cores. Every mutation happens kernel-side under the lock
    /// in `interrupts/kernel_semaphore.zig`; the reads below are an
    /// unsynchronised fast path that the syscall re-checks.
    counter: u32,

    pub fn create(init: u32) Semaphore {
        return Semaphore{
            .max_value = init,
            .counter = init,
        };
    }

    pub fn acquire(self: *Semaphore) void {
        if (self.counter > 0) {
            const event = SemaphoreEvent{
                .object = self,
            };
            var result: bool = false;
            while (!result) {
                hal.irq.trigger_supervisor_call(c.sys_semaphore_acquire, &event, &result);
            }
        }
    }

    pub fn release(self: *Semaphore) void {
        if (self.counter < self.max_value) {
            const event = SemaphoreEvent{
                .object = self,
            };
            var result: bool = false;
            hal.irq.trigger_supervisor_call(c.sys_semaphore_release, &event, &result);
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
            event.object.counter -= 1;
            hal.irq.impl().calls[id] += 1;
            const result: *volatile bool = @ptrCast(@alignCast(out));
            result.* = true;
        }

        pub fn release(id: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) callconv(.c) void {
            const event: *const volatile syscall_handlers.SemaphoreEvent = @ptrCast(@alignCast(arg));
            event.object.counter += 1;
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
    try std.testing.expectEqual(1, sut.counter);
    try std.testing.expectEqual(0, hal.irq.impl().calls[c.sys_semaphore_release]);
    sut.release();
    try std.testing.expectEqual(1, hal.irq.impl().calls[c.sys_semaphore_release]);
    try std.testing.expectEqual(2, sut.counter);

    sut.acquire();
    sut.acquire();
    sut.acquire();
    sut.acquire();
    try std.testing.expectEqual(4, hal.irq.impl().calls[c.sys_semaphore_acquire]);
    try std.testing.expectEqual(0, sut.counter);

    sut.release();
    try std.testing.expectEqual(2, hal.irq.impl().calls[c.sys_semaphore_release]);
    try std.testing.expectEqual(1, sut.counter);
    sut.release();
    sut.release();
    sut.release();
    sut.release();
    sut.release();
    sut.release();
    try std.testing.expectEqual(4, hal.irq.impl().calls[c.sys_semaphore_release]);
    try std.testing.expectEqual(3, sut.counter);
}
