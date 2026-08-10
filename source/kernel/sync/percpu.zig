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

//! Per-CPU data.
//!
//! Cortex-M has no per-core general-purpose register -- there is no A-profile
//! `TPIDRPRW` to hang a per-CPU base pointer off -- so per-CPU data is an array
//! indexed by `coreid()`, which on the rp2350 is a single-cycle SIO load.
//!
//! The point of a per-CPU slot is that it needs *no* lock: only one core ever
//! writes it. That makes it the right answer for a surprising amount of the
//! synchronization inventory -- the scheduler's `current`, `preempt_count`, the
//! syscall profiler's ~35 counters, the MPU programming cursor -- and it is
//! strictly cheaper than any lock. Reach for it before reaching for `SpinLock`.
//!
//! Two rules come with it:
//!
//!   * **A slot is not safe against this core's own interrupt handlers.** A
//!     read-modify-write of a per-CPU counter that both thread and handler
//!     context touch still needs interrupts masked. Per-CPU removes the *cross
//!     core* race, not the preemption one.
//!   * **Aggregate reads are approximate.** `fold` walks the other cores' slots
//!     while they are running; a total is a snapshot, not an instant. That is
//!     fine for `/proc` counters and wrong for anything that must balance.
//!
//! No padding between slots, deliberately: the rp2350 has no data cache for
//! SRAM, so there is no false sharing to pad against, and the XIP cache is
//! shared. Padding here would cost RAM for nothing. (`sync.Isolated` exists for
//! the different problem of the exclusive-monitor reservation granule, which
//! applies to lock words, not to per-CPU data.)

const std = @import("std");

const config = @import("config");
const hal = @import("hal");

/// Whether more than one core actually runs kernel code -- `CONFIG_PROCESS_SMP`.
///
/// Deliberately not `hal.cpu.number_of_cores() > 1`. The RP2350 *has* two cores
/// and says so, but YasOS parks core 1 until phase 6, and paying for cross-core
/// synchronization on a chip where nothing else is running is pure cost.
///
/// What this does **not** switch off is everything the preemptive scheduler
/// needs: atomics stay atomic and interrupt masks stay in place, because a
/// read-modify-write shared between thread and handler context races on one core
/// exactly as it does on two.
pub const smp: bool = config.process.smp;

/// Number of cores this build schedules on.
///
/// Sizes every per-CPU array in the kernel, and `current_core()` must always be
/// a valid index into one. One unless SMP is on -- a second slot no core can
/// ever reach is memory spent on nothing.
pub const core_count: usize = if (smp) hal.cpu.number_of_cores() else 1;

/// The calling core's index.
///
/// A compile-time zero without SMP, which lets the whole `percpu[coreid()]`
/// indexing fold away -- on the rp2350 that removes an SIO load from every
/// preempt_disable, every lock and every unlock.
pub inline fn current_core() usize {
    if (comptime !smp) return 0;
    return hal.cpu.coreid();
}

/// One `T` per core.
pub fn PerCpu(comptime T: type) type {
    return struct {
        slots: [core_count]T,

        const Self = @This();

        /// All cores start from the same value. Written as a function rather
        /// than a default so `T` need not be default-constructible.
        pub fn init(value: T) Self {
            return .{ .slots = @splat(value) };
        }

        /// This core's slot. The only one that may be written without further
        /// synchronization.
        pub inline fn current(self: *Self) *T {
            return &self.slots[current_core()];
        }

        pub inline fn current_const(self: *const Self) *const T {
            return &self.slots[current_core()];
        }

        /// Another core's slot.
        ///
        /// Only two things may legitimately do this: cross-core wake-ups that
        /// know what they are doing, and aggregate reads. Everything else wants
        /// `current()`.
        pub inline fn of(self: *Self, core: usize) *T {
            return &self.slots[core];
        }

        pub inline fn all(self: *const Self) *const [core_count]T {
            return &self.slots;
        }

        /// Combine every core's slot -- the counterpart to per-CPU counters,
        /// which are only meaningful summed.
        ///
        /// Torn against concurrent writers by construction; see the module
        /// comment.
        pub fn fold(
            self: *const Self,
            comptime Accumulator: type,
            initial: Accumulator,
            comptime combine: fn (Accumulator, T) Accumulator,
        ) Accumulator {
            var accumulator = initial;
            for (self.slots) |slot| accumulator = combine(accumulator, slot);
            return accumulator;
        }
    };
}

const testing = std.testing;

test "Sync.PerCpu.CoreCountAndIdAgree" {
    // `coreid()` indexes arrays sized by `number_of_cores()`. The host hal used
    // to report four cores with `coreid()` pinned to 1; on a two-core board that
    // is an out-of-bounds slot that no bring-up path initialises.
    try testing.expect(core_count >= 1);
    try testing.expect(current_core() < core_count);
}

test "Sync.PerCpu.WritesLandInTheCallingCoresSlotOnly" {
    const Cpu = hal.CpuStub;
    const restore = Cpu.coreid();
    defer Cpu.set_coreid(@intCast(restore));

    var counters = PerCpu(u32).init(0);

    Cpu.set_coreid(0);
    counters.current().* += 7;

    if (core_count > 1) {
        Cpu.set_coreid(1);
        // The whole property: core 1 sees its own slot untouched by core 0.
        try testing.expectEqual(@as(u32, 0), counters.current().*);
        counters.current().* += 5;
        try testing.expectEqual(@as(u32, 5), counters.current().*);

        Cpu.set_coreid(0);
        try testing.expectEqual(@as(u32, 7), counters.current().*);
        try testing.expectEqual(@as(u32, 5), counters.of(1).*);
    }
}

test "Sync.PerCpu.FoldSumsEverySlot" {
    const Cpu = hal.CpuStub;
    const restore = Cpu.coreid();
    defer Cpu.set_coreid(@intCast(restore));

    var counters = PerCpu(u32).init(0);
    for (0..core_count) |core| counters.of(core).* = @intCast(core + 1);

    const sum = struct {
        fn add(accumulator: u32, slot: u32) u32 {
            return accumulator + slot;
        }
    }.add;

    // 1 + 2 + ... + core_count
    const expected: u32 = @intCast(core_count * (core_count + 1) / 2);
    try testing.expectEqual(expected, counters.fold(u32, 0, sum));
}

test "Sync.PerCpu.InitSeedsEveryCoreIdentically" {
    var flags = PerCpu(bool).init(true);
    for (flags.all()) |slot| try testing.expect(slot);
}
