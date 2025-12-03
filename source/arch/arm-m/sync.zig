// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

pub inline fn data_synchronization_barrier() void {
    asm volatile (
        \\ dsb sy
        \\ dmb sy
    );
}

pub inline fn instruction_synchronization_barrier() void {
    asm volatile ("isb sy" ::: .{ .memory = true });
}

pub inline fn wait_for_event() void {
    asm volatile ("wfe" ::: .{ .memory = true });
}

pub inline fn wait_for_interrupt() void {
    asm volatile ("wfi" ::: .{ .memory = true });
}

pub inline fn disable_interrupts() void {
    asm volatile ("cpsid i" ::: .{ .memory = true });
}

pub inline fn enable_interrupts() void {
    asm volatile ("cpsie i" ::: .{ .memory = true });
}

pub inline fn memory_barrier_release() void {
    asm volatile ("dmb" ::: .{ .memory = true });
}

pub inline fn memory_barrier_acquire() void {
    asm volatile ("dmb" ::: .{ .memory = true });
}

pub inline fn save_and_disable_interrupts() usize {
    return asm volatile (
        \\ mrs %[ret], PRIMASK
        \\ cpsid i
        : [ret] "=r" (-> usize),
        :
        : .{ .memory = true });
}

pub inline fn restore_interrupts(primask: usize) void {
    asm volatile (
        \\ msr PRIMASK, %[mask]
        :
        : [mask] "r" (primask),
        : .{ .memory = true });
}
