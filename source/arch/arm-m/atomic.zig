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

//! Cortex-M exclusive-monitor policy for the generic primitives in
//! `source/kernel/sync/`.
//!
//! Nothing here is a lock. This file answers the one question the generic code
//! cannot answer for itself -- how wide an atomic this core can perform without
//! silently turning into a libcall -- plus the one instruction that has to be
//! issued from the context-switch path.
//!
//! The atomic operations themselves are Zig's `@atomicLoad` / `@atomicStore` /
//! `@atomicRmw` / `@cmpxchg*`, which lower to LDAEX/STLEX on `thumbv8m.main`.
//! Hand-written assembly would buy nothing and would hide the operations from
//! the optimiser. See `tests/verify_atomics.sh` for the disassembly gate that
//! checks the lowering actually happened.

/// Widest atomic read-modify-write this core performs inline.
///
/// Cortex-M33 (Armv8-M Mainline) has LDREX/STREX and the byte and halfword
/// forms, but **no LDREXD**. A 64-bit `@atomicRmw` therefore does not lower to
/// an exclusive pair at all: it lowers to an `__atomic_*` libcall out of
/// compiler-rt, which serialises on a global lock table. That is not lock-free,
/// it is not safe to call from an exception handler, and no diagnostic is
/// emitted when it happens. `kernel.sync.Atomic` refuses anything wider than
/// this so the failure is a compile error rather than a deadlock at 03:00.
///
/// The counters this rules out (`tick_counter`, most of `perf_profile`) are
/// meant to become per-CPU rather than atomic.
pub const lock_free_bits: u16 = 32;

/// Drop any exclusive reservation held by this core.
///
/// A thread preempted between its LDREX and its STREX must not resume with a
/// live reservation, or its eventual STREX can succeed against a monitor state
/// that belongs to whatever ran in between. The architecture is widely believed
/// to clear the local monitor on exception entry, but the guarantee is worth
/// exactly one cycle to not depend on -- the context-switch store path issues
/// this unconditionally.
pub inline fn clear_exclusive() void {
    asm volatile ("clrex" ::: .{ .memory = true });
}
