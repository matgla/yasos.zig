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

// Cortex-M exclusive-monitor policy for the generic primitives in
// `source/kernel/sync/`: how wide an atomic this core can perform without
// silently turning into a libcall, plus the one instruction the context-switch
// path has to issue. The operations themselves are Zig's atomic builtins, which
// lower to LDAEX/STLEX on `thumbv8m.main`; `tests/verify_atomics.sh` is the
// disassembly gate that checks the lowering happened.

/// Widest atomic read-modify-write this core performs inline. The Cortex-M33 has
/// LDREX/STREX and the byte and halfword forms but no LDREXD, so a 64-bit
/// `@atomicRmw` lowers to an `__atomic_*` libcall serialising on a global lock
/// table -- not lock-free, not safe from an exception handler, and silent.
/// `kernel.sync.Atomic` refuses anything wider so it is a compile error instead.
pub const lock_free_bits: u16 = 32;

/// Drop any exclusive reservation held by this core. A thread preempted between
/// its LDREX and STREX must not resume with a live reservation, or its STREX can
/// succeed against a monitor state belonging to whatever ran in between. The
/// context-switch store path issues this unconditionally; it costs one cycle.
pub inline fn clear_exclusive() void {
    asm volatile ("clrex" ::: .{ .memory = true });
}
