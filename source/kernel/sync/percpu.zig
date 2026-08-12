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

// Per-CPU data: an array indexed by `coreid()`, since Cortex-M has no per-core
// register to hang a base pointer off. A slot needs no lock because only one
// core writes it, but it is still not safe against this core's own interrupt
// handlers, and `fold` reads other cores' slots while they run, so aggregates
// are snapshots. No padding: SRAM has no data cache, so no false sharing.

const std = @import("std");

const config = @import("config");
const hal = @import("hal");

/// Whether more than one core actually runs kernel code -- `CONFIG_PROCESS_SMP`.
/// Not `hal.cpu.number_of_cores() > 1`: the chip may have cores this build parks.
/// Turning it off does not relax atomics or interrupt masking, which the
/// preemptive scheduler needs on one core just as much.
pub const smp: bool = config.process.smp;

/// Number of cores this build schedules on. Sizes every per-CPU array, and
/// `current_core()` must always be a valid index into one.
pub const core_count: usize = if (smp) hal.cpu.number_of_cores() else 1;

/// The calling core's index. A comptime zero without SMP, so the indexing folds
/// away and the SIO load disappears from every lock and unlock.
pub inline fn current_core() usize {
    if (comptime !smp) return 0;
    return hal.cpu.coreid();
}

/// One `T` per core.
pub fn PerCpu(comptime T: type) type {
    return struct {
        slots: [core_count]T,

        const Self = @This();

        /// All cores start from the same value. A function rather than a default
        /// so `T` need not be default-constructible.
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

        /// Another core's slot. Only for cross-core wake-ups and aggregate
        /// reads; everything else wants `current()`.
        pub inline fn of(self: *Self, core: usize) *T {
            return &self.slots[core];
        }

        pub inline fn all(self: *const Self) *const [core_count]T {
            return &self.slots;
        }

        /// Combine every core's slot. Torn against concurrent writers by
        /// construction.
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
    // `coreid()` indexes arrays sized by `number_of_cores()`.
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
