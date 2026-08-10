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

//! Kernel synchronization primitives.
//!
//! Phase 0 of `docs/smp_plan.md`: everything here works identically on one core
//! and on two, so it can land, be reviewed and be tested before a second core
//! exists. Nothing in this directory changes single-core behaviour.
//!
//! Three things live here and the split is deliberate:
//!
//!   * `Atomic(T)` -- `std.atomic.Value` that refuses widths the CPU would turn
//!     into a libcall.
//!   * `SpinLock` -- one portable implementation, four tiny arch hooks.
//!   * `placement` -- the assertion that a lock is somewhere its exclusives
//!     actually work.
//!
//! What is *not* here, and where it went instead:
//!
//!   * Barriers. Ordering belongs on the operation (`.acquire` / `.release` on
//!     the atomic itself, which lowers to LDAEX/STL), not in a separate `dmb`
//!     next to it. The RP2350 has no data cache for SRAM and its XIP cache is
//!     shared between cores, so no cache maintenance is ever required either.
//!   * Sleeping mutexes and the lock hierarchy. Phase 4.

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
/// the board's memory map.
///
/// Must run after the board is up, because the PSRAM window's size is not known
/// until external memory has been detected -- before that the layout reports
/// size 0 and `is_coherent` accepts everything.
///
/// Currently one hook: `libs/oop`'s shared reference count. That counter is a
/// heap allocation, and for a process-owned `IFile`/`IDirectory` the heap
/// backing it is the process pool, whose tier 1 is PSRAM. `libs/oop` has no
/// memory map of its own, so it asks.
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
