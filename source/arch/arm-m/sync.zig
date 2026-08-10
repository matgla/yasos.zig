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

const hal = @import("hal");

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

/// Idle for one spin iteration while waiting for a lock.
///
/// WFE parks the core until the event register is set, and `signal_event()` in
/// the unlock path is what sets it. The pairing is race-free in the direction
/// that matters: a SEV that lands between a waiter's failed acquire and its WFE
/// sets the event register, so the WFE falls straight through rather than
/// sleeping through the wake-up it was waiting for.
///
/// This does not sleep indefinitely when the lock holder is on *this* core (a
/// preempted thread, or a handler that interrupted a non-irqsave holder):
/// asynchronous exceptions are WFE wake-up events even with PRIMASK set, so
/// SysTick alone guarantees the spin loop keeps making progress -- which is
/// also what keeps the deadlock detector's iteration budget ticking.
pub inline fn cpu_relax() void {
    asm volatile ("wfe" ::: .{ .memory = true });
}

/// Wake every core parked in `cpu_relax()`.
pub inline fn signal_event() void {
    asm volatile ("sev" ::: .{ .memory = true });
}

/// Whether the caller is running in an exception handler.
///
/// IPSR holds the active exception number, and zero means thread mode. The
/// sleeping mutex uses this to refuse an acquire from handler context, where
/// blocking the "current process" would deschedule whatever the handler
/// interrupted and never come back.
pub inline fn in_handler_mode() bool {
    return asm volatile ("mrs %[ret], ipsr"
        : [ret] "=r" (-> u32),
    ) != 0;
}

/// Identity of the current execution context, for lock ownership tracking.
///
/// On Cortex-M this is the core: there is no per-core general-purpose register
/// (no A-profile `TPIDRPRW`), so it is the SIO CPUID load. Thread mode and
/// handler mode on the same core deliberately share an id -- an interrupt
/// handler taking a spinlock its own core already holds in thread mode is the
/// bug the ownership check exists to name.
pub inline fn owner_id() u32 {
    return hal.cpu.coreid();
}
