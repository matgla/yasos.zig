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

//! Shared reference counts, for the loader's two of them.
//!
//! Semantically identical to `source/kernel/sync/refcount.zig` and to
//! `libs/oop`'s `refcount`, and it exists separately only because `yasld` is a
//! standalone module that imports neither. Forty lines of duplication is the
//! cheaper half of that trade against giving the dynamic loader a dependency on
//! the kernel; if a fourth copy ever appears, that calculus has changed. Keep
//! the three in step -- the ordering notes below are the contract.
//!
//! ## What this does and does not fix
//!
//! It makes each individual increment and decrement indivisible. It does **not**
//! make `Loader.get_shared_data` safe: that is a check-then-act across a
//! `StringHashMap` lookup and an insert, so two contexts can both miss, both
//! create, and one `put` overwrites the other -- leaking an image and leaving a
//! `users` count that never reaches zero. Nor does it stop a concurrent
//! `get_shared_data` from resurrecting a pointer `unload_module` has just
//! decided to free. Both of those need `loader_lock` (phase 4 of
//! `docs/smp_plan.md`); the atomic is a prerequisite, not the fix.

const std = @import("std");

fn Counter(comptime Pointer: type) type {
    const info = @typeInfo(Pointer);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("refcount takes a single-item pointer, got " ++ @typeName(Pointer));
    }
    const T = info.pointer.child;
    if (@typeInfo(T) != .int) {
        @compileError("refcount takes a pointer to an integer, got " ++ @typeName(T));
    }
    // Cortex-M33 has no LDREXD, so a 64-bit atomic becomes a lock-taking
    // `__atomic_*` libcall rather than failing to build.
    if (@sizeOf(T) * 8 > 32) {
        @compileError("refcount on " ++ @typeName(T) ++ " would not be lock-free on this target");
    }
    return T;
}

/// A counter with exactly one owner. Plain: nothing else can reach a counter
/// that has not been published yet.
pub fn init(counter: anytype) void {
    comptime _ = Counter(@TypeOf(counter));
    counter.* = 1;
}

/// Take a reference. Monotonic: an increment is only ever performed by a context
/// that already holds one, so the object is provably alive across it.
pub fn acquire(counter: anytype) void {
    const T = Counter(@TypeOf(counter));
    _ = @atomicRmw(T, counter, .Add, 1, .monotonic);
}

/// Drop a reference. Returns true if this was the last one.
///
/// `acq_rel`: release so writes made through the object are visible to whoever
/// destroys it, acquire so the destroyer sees everyone else's writes first.
pub fn release(counter: anytype) bool {
    const T = Counter(@TypeOf(counter));
    return @atomicRmw(T, counter, .Sub, 1, .acq_rel) == 1;
}

/// The current count. Diagnostics only; stale as soon as it is read.
pub fn get(counter: anytype) Counter(@TypeOf(counter)) {
    const T = Counter(@TypeOf(counter));
    return @atomicLoad(T, counter, .monotonic);
}
