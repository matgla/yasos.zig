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

const builtin = @import("builtin");

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

const has_stack_limit = builtin.cpu.has(.arm, .has_v8m);

/// Stack a masked section may need below the point it masks. A fault in such a
/// section cannot be survived: it holds a spinlock over core kernel state, and
/// the exception frame does not fit either, so there is nothing to resume.
/// Syscalls run on the process stack, so the process is killed here instead,
/// before the section starts. No sweep in user_fault_test or
/// scripts/stack_overflow_sweep.py gets through this much and still faults.
const masked_section_stack: usize = 320;

/// Kill the process rather than let it start something it may overflow halfway
/// through. The undefined instruction takes the ordinary fault path, which sees a
/// thread holding at most sleeping mutexes.
noinline fn stack_would_overflow() void {
    if (in_handler_mode()) return;
    // A nested section cannot be left any more, so it uses up the margin instead.
    const primask = asm volatile ("mrs %[ret], PRIMASK"
        : [ret] "=r" (-> usize),
    );
    if (primask != 0) return;
    // Thread mode on MSP is boot, where PSPLIM describes nothing.
    const control = asm volatile ("mrs %[ret], CONTROL"
        : [ret] "=r" (-> usize),
    );
    if ((control & 2) == 0) return;
    asm volatile ("udf #0");
}

/// Kill the calling process unless it has `bytes` of stack left. A no-op from
/// handlers and on the boot stack.
pub inline fn require_stack(bytes: usize) void {
    if (comptime !has_stack_limit) return;
    const sp = asm volatile ("mov %[ret], sp"
        : [ret] "=r" (-> usize),
    );
    const limit = asm volatile ("mrs %[ret], psplim"
        : [ret] "=r" (-> usize),
    );
    // Wraps to a huge value on MSP, whose stack lies elsewhere; the slow path
    // sorts out the rest.
    if (sp -% limit < bytes) stack_would_overflow();
}

/// For a section about to take a spinlock. The bare masked sections, such as
/// `preempt_disable`, are a few instructions deep and run far too often to pay
/// for this.
pub inline fn require_stack_for_masked_section() void {
    require_stack(masked_section_stack);
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

/// Idle for one spin iteration while waiting for a lock. WFE parks the core
/// until the event register is set, which `signal_event()` in the unlock path
/// does. Race-free in the direction that matters: a SEV landing between a
/// waiter's failed acquire and its WFE sets the register, so the WFE falls
/// straight through. It also cannot sleep indefinitely against a holder on this
/// core, since asynchronous exceptions are WFE wake-up events even with PRIMASK
/// set.
pub inline fn cpu_relax() void {
    asm volatile ("wfe" ::: .{ .memory = true });
}

/// Wake every core parked in `cpu_relax()`.
pub inline fn signal_event() void {
    asm volatile ("sev" ::: .{ .memory = true });
}

/// Whether the caller is running in an exception handler -- IPSR holds the
/// active exception number, and zero means thread mode. The sleeping mutex uses
/// it to refuse a blocking acquire from handler context, which would deschedule
/// whatever the handler interrupted and never come back.
pub inline fn in_handler_mode() bool {
    return asm volatile ("mrs %[ret], ipsr"
        : [ret] "=r" (-> u32),
    ) != 0;
}

/// Identity of the current execution context, for lock ownership tracking. On
/// Cortex-M that is the core -- there is no per-core general-purpose register,
/// so it is the SIO CPUID load. Thread and handler mode on one core share an id
/// deliberately: a handler taking a spinlock its own core already holds is the
/// bug the ownership check exists to name.
pub inline fn owner_id() u32 {
    return hal.cpu.coreid();
}
