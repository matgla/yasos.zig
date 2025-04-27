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

const syscall = @import("interrupts/system_call.zig");

const atomic = @import("hal").atomic;

const c = @cImport({
    @cInclude("syscalls.h");
});

pub const Semaphore = struct {
    counter: atomic.Atomic(u32),

    pub fn create(init: u32) Semaphore {
        return Semaphore{
            .counter = atomic.Atomic(u32).create(init),
        };
    }

    pub fn acquire(self: *Semaphore) void {
        const event = syscall.SemaphoreEvent{
            .object = self,
        };
        var result: bool = false;
        while (!result) {
            syscall.trigger(c.sys_semaphore_acquire, &event, &result);
        }
    }

    pub fn release(self: *Semaphore) void {
        const event = syscall.SemaphoreEvent{
            .object = self,
        };
        syscall.trigger(c.sys_semaphore_release, &event, null);
    }
};
