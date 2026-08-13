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

// A per-core preemption barrier. Not mutual exclusion -- it provides nothing at
// all against a second core; sites protecting shared structures want a named
// lock instead. A reschedule refused while preemption is disabled is recorded
// in `need_resched` and re-pended by `preempt_enable`, rather than lost.

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

/// Refuse preemption on this core until the matching `preempt_enable()`. Nests.
/// Masks interrupts because this core's handlers touch the same slot.
pub fn preempt_disable() void {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    const self = state.current();
    self.count += 1;
}

/// Whether an unbalanced release is a panic or a clamp. Off in ReleaseFast so a
/// latent accounting bug cannot turn into a boot-time panic on a shipped image.
const panic_on_unbalanced_release = std.debug.runtime_safety;

/// Releases that had no matching `preempt_disable`, per core.
var unbalanced_releases: percpu.PerCpu(u32) = .init(0);

pub fn unbalanced_release_count() u32 {
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    return unbalanced_releases.current().*;
}

/// Allow preemption again, and deliver any reschedule refused in the meantime.
/// The re-trigger happens after the count reaches zero and interrupts are
/// restored, so the PendSV it pends can actually be taken.
pub fn preempt_enable() void {
    release(true);
}

/// `preempt_enable()` for the sites that are knowingly unbalanced -- only the
/// deprecated `unblock_context_switch` alias, so the strict version can panic.
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
            // Clamp: leaving preemption refused because the accounting went
            // negative would hang the system outright.
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

/// Record that this core owes a reschedule. Called from the scheduler entry
/// point when it declines to switch; safe from handler context.
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

/// Drop any recorded reschedule without delivering it, for paths that are about
/// to switch anyway.
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

/// `hal.irq` is an instance, so the enum is reached through its type.
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
    // Still disabled: the outer window has not closed yet.
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
    // The refused switch is re-pended, not lost.
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

    // Core 1 is unaffected, which is what makes the counter safe without a lock.
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
