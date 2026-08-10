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

//! "Do not preempt me" -- a per-core preemption barrier.
//!
//! This is one of the three meanings `block_context_switch()` currently
//! conflates, and the only one that is genuinely about *this core's* execution
//! rather than about shared data. Sites that protect a per-core invariant
//! (nothing another core could touch) want this; sites that protect a shared
//! structure want a named lock; sites that must keep PendSV out of a specific
//! instruction window want this **plus** the deferred re-trigger below.
//!
//! ## Deferring, not dropping
//!
//! The behaviour that separates this from what it replaces: when the scheduler
//! is asked to run while preemption is disabled, it records `need_resched` and
//! returns instead of silently doing nothing. `preempt_enable()` sees the flag
//! on the way out and re-triggers PendSV.
//!
//! That fixes a live single-core defect, independent of SMP. Today a SysTick
//! landing inside a block window is simply lost: the process that happened to be
//! running gets a free extra timeslice, and nothing accounts for it. Under load
//! -- a `tcc` compile inside a syscall-heavy shell -- that is a fairness and
//! latency bug in a scheduler that is supposed to be round-robin.
//!
//! ## What it is not
//!
//! It is not mutual exclusion. On a second core it provides exactly zero, which
//! is precisely why the 37 sites that use `block_context_switch()` as a lock
//! have to be classified rather than mechanically renamed onto this.

const std = @import("std");

const arch = @import("arch");
const hal = @import("hal");

const percpu = @import("percpu.zig");

/// Per-core state. Written only by its own core, always with interrupts masked,
/// so the fields need no atomics -- see `percpu.zig`.
const State = struct {
    /// Nesting depth. Preemption is allowed only at zero.
    count: u32 = 0,
    /// A reschedule was requested and refused while `count > 0`.
    pending: bool = false,
};

var state: percpu.PerCpu(State) = .init(.{});

/// Refuse preemption on this core until the matching `preempt_enable()`.
///
/// Nests. The counter update runs with interrupts masked because the interrupt
/// handlers on this core touch the same slot.
pub fn preempt_disable() void {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    const self = state.current();
    self.count += 1;
}

/// Whether an unbalanced release is a panic or a clamp.
///
/// A panic is what this deserves: the clamp is why every unbalanced pair in the
/// tree has stayed invisible. It is off in ReleaseFast so a mis-analysed path
/// cannot turn a latent accounting bug into a boot-time panic on a shipped
/// image, and on in Debug/ReleaseSafe -- which is what `zig build test` and
/// `run_qemu_smoke.sh --safe` build, so the suites do surface them.
const panic_on_unbalanced_release = std.debug.runtime_safety;

/// Releases that had no matching `preempt_disable`, per core.
///
/// Exposed rather than merely clamped, so "we know some sites are unbalanced"
/// is a number someone can watch go to zero instead of a comment.
var unbalanced_releases: percpu.PerCpu(u32) = .init(0);

pub fn unbalanced_release_count() u32 {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    return unbalanced_releases.current().*;
}

/// Allow preemption again, and deliver any reschedule that was refused in the
/// meantime.
///
/// The re-trigger happens *after* the count reaches zero and after interrupts
/// are restored, so the PendSV it pends can actually be taken.
pub fn preempt_enable() void {
    release(true);
}

/// `preempt_enable()` for the sites that are knowingly unbalanced.
///
/// Only the deprecated `unblock_context_switch` alias calls this. It exists so
/// the strict version can be strict: several release sites in the tree today
/// have no matching acquire on the same path -- the tail of `delete_process`
/// releases in a loop, and three releases are issued from assembly to close
/// windows opened in Zig by functions that never return normally. Those are
/// phase 3 work; until then they must not take the kernel down.
pub fn preempt_enable_unbalanced() void {
    release(false);
}

fn release(comptime strict: bool) void {
    const deliver = blk: {
        const flags = arch.sync.save_and_disable_interrupts();
        defer arch.sync.restore_interrupts(flags);
        const self = state.current();
        if (self.count == 0) {
            unbalanced_releases.current().* +%= 1;
            if (strict and panic_on_unbalanced_release) {
                @panic("preempt_enable without a matching preempt_disable");
            }
            // Clamp, as `unblock_context_switch` always has: leaving preemption
            // refused because the accounting went negative would hang the
            // system outright.
            self.pending = false;
            break :blk false;
        }
        self.count -= 1;
        if (self.count != 0) break :blk false;
        if (!self.pending) break :blk false;
        self.pending = false;
        break :blk true;
    };
    if (deliver) hal.irq.trigger(.pendsv);
}

/// Whether preemption is currently refused on this core.
pub fn preempt_disabled() bool {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    return state.current().count != 0;
}

/// Current nesting depth on this core. Diagnostics and assertions.
pub fn preempt_count() u32 {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    return state.current().count;
}

/// Record that this core owes a reschedule.
///
/// Called from the scheduler entry point when it declines to switch. Safe from
/// handler context: it only touches this core's slot.
pub fn set_need_resched() void {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    state.current().pending = true;
}

/// Whether this core owes a reschedule. Does not clear it.
pub fn need_resched() bool {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    return state.current().pending;
}

/// Drop any recorded reschedule for this core without delivering it.
///
/// For the paths that are about to switch anyway, so the flag does not survive
/// into the next window and pend a redundant PendSV.
pub fn clear_need_resched() void {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    state.current().pending = false;
}

/// Reset this core's state. Test support and core bring-up only.
pub fn reset() void {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    state.current().* = .{};
    unbalanced_releases.current().* = 0;
}

const testing = std.testing;

/// `hal.irq` is an instance, so the enum is reached through its type. Works
/// against every hal backend, unlike naming the stub directly.
const IrqType = @TypeOf(hal.irq).IrqType;

fn pendsv_count() u32 {
    return hal.irq.impl().irq_calls[@intFromEnum(IrqType.pendsv)];
}

test "Sync.Preempt.NestsAndOnlyReleasesAtZero" {
    reset();
    defer reset();

    try testing.expect(!preempt_disabled());
    preempt_disable();
    try testing.expectEqual(@as(u32, 1), preempt_count());
    preempt_disable();
    try testing.expectEqual(@as(u32, 2), preempt_count());
    try testing.expect(preempt_disabled());

    preempt_enable();
    // Still disabled: the outer window has not closed yet. Releasing at the
    // inner `enable` is the classic nesting bug and the reason the counter
    // exists at all.
    try testing.expect(preempt_disabled());
    preempt_enable();
    try testing.expect(!preempt_disabled());
}

test "Sync.Preempt.DeferredRescheduleIsDeliveredNotDropped" {
    reset();
    defer reset();
    defer hal.irq.impl().clear();
    hal.irq.impl().clear();

    preempt_disable();
    // What SysTick does when it finds preemption disabled.
    set_need_resched();
    try testing.expect(need_resched());
    try testing.expectEqual(0, pendsv_count());

    preempt_enable();
    // The whole point: the switch that was refused is re-pended rather than
    // lost, so the running process does not get a free extra timeslice.
    try testing.expect(!need_resched());
    try testing.expectEqual(1, pendsv_count());
}

test "Sync.Preempt.DeferredRescheduleWaitsForTheOutermostRelease" {
    reset();
    defer reset();
    defer hal.irq.impl().clear();
    hal.irq.impl().clear();

    preempt_disable();
    preempt_disable();
    set_need_resched();

    preempt_enable();
    try testing.expectEqual(0, pendsv_count());
    try testing.expect(need_resched());

    preempt_enable();
    try testing.expectEqual(1, pendsv_count());
}

test "Sync.Preempt.NoRescheduleMeansNoSpuriousPendsv" {
    reset();
    defer reset();
    defer hal.irq.impl().clear();
    hal.irq.impl().clear();

    preempt_disable();
    preempt_enable();
    try testing.expectEqual(0, pendsv_count());
}

test "Sync.Preempt.UnbalancedReleaseIsCountedAndClamped" {
    reset();
    defer reset();
    defer hal.irq.impl().clear();
    hal.irq.impl().clear();

    try testing.expectEqual(@as(u32, 0), unbalanced_release_count());

    // The tolerant path the deprecated `unblock_context_switch` alias uses.
    // Clamping matters: going negative and staying "disabled" would hang the
    // system, which is why the original clamped -- the defect was doing it
    // silently.
    preempt_enable_unbalanced();
    try testing.expectEqual(@as(u32, 1), unbalanced_release_count());
    try testing.expect(!preempt_disabled());
    try testing.expectEqual(@as(u32, 0), preempt_count());

    // And a clamped release must not leave a reschedule owed to nobody.
    try testing.expect(!need_resched());
    try testing.expectEqual(0, pendsv_count());
}

test "Sync.Preempt.StateIsPerCoreNotGlobal" {
    if (percpu.core_count < 2) return error.SkipZigTest;

    const Cpu = hal.CpuStub;
    const restore = Cpu.coreid();
    defer Cpu.set_coreid(@intCast(restore));

    Cpu.set_coreid(0);
    reset();
    Cpu.set_coreid(1);
    reset();

    Cpu.set_coreid(0);
    preempt_disable();
    set_need_resched();

    // Core 1 is unaffected -- this is the property that makes the counter safe
    // without a lock. A shared counter would have core 1 refusing to schedule
    // because core 0 is in a critical section it has nothing to do with.
    Cpu.set_coreid(1);
    try testing.expect(!preempt_disabled());
    try testing.expect(!need_resched());

    Cpu.set_coreid(0);
    try testing.expect(preempt_disabled());
    preempt_enable();
    reset();
    Cpu.set_coreid(1);
    reset();
}
