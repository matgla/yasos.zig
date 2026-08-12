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

// Kernel synchronization primitives. Everything here works identically on one
// core and on two. No standalone barriers: ordering belongs on the operation
// (`.acquire`/`.release`, which lower to LDAEX/STL), and the RP2350 needs no
// cache maintenance -- SRAM is uncached and the XIP cache is shared.

pub const Atomic = @import("atomic.zig").Atomic;
pub const atomic = @import("atomic.zig");

pub const SpinLock = @import("spinlock.zig").SpinLock;
pub const IrqState = @import("spinlock.zig").IrqState;
pub const Isolated = @import("spinlock.zig").Isolated;
pub const reservation_granule_bytes = @import("spinlock.zig").reservation_granule_bytes;

pub const placement = @import("placement.zig");

pub const refcount = @import("refcount.zig");

pub const Seq64 = @import("seqlock.zig").Seq64;

pub const locks = @import("locks.zig");
pub const RankedMutex = @import("mutex.zig").RankedMutex;
pub const Rank = locks.Rank;
pub const Ranked = locks.Ranked;
pub const RecursiveSpinLock = locks.RecursiveSpinLock;

pub const PerCpu = @import("percpu.zig").PerCpu;
pub const percpu = @import("percpu.zig");

pub const preempt = @import("preempt.zig");
pub const preempt_disable = preempt.preempt_disable;
pub const preempt_enable = preempt.preempt_enable;

/// Install the hooks that let library code outside this tree be checked against
/// the board's memory map. Must run after external memory has been detected, or
/// the PSRAM window reports size 0 and `is_coherent` accepts everything.
pub fn init() void {
    const oop = @import("interface");
    oop.refcount.placement_check = &refcount_placement_check;
}

fn refcount_placement_check(counter: *const i32) void {
    placement.assert_coherent(counter);
}

comptime {
    _ = @import("atomic.zig");
    _ = @import("spinlock.zig");
    _ = @import("placement.zig");
    _ = @import("percpu.zig");
    _ = @import("preempt.zig");
    _ = @import("refcount.zig");
    _ = @import("seqlock.zig");
    _ = @import("locks.zig");
    _ = @import("mutex.zig");
}
