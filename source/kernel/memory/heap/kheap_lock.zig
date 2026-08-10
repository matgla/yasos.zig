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

//! The kernel heap lock -- `__malloc_lock` / `__malloc_unlock`, rank `kheap`.
//!
//! The kernel heap **is** newlib malloc: the dynamic loader allocates through it
//! during execve and lazy PLT resolve, and so does every kernel structure. Its
//! free list is the single most consequential shared structure in the tree; the
//! comment this replaces records what happens without a lock, which is a wild
//! `pop {pc} == 0` HardFault in `sbrk_aligned` under load.
//!
//! ## Why it is recursive, and why that is not a choice
//!
//! newlib's `realloc` takes `__malloc_lock` and then calls the also-locking
//! `_malloc_r` / `_free_r`. The recursion is in libc's API, not in our design,
//! which is why `RecursiveRanked` has a second instantiation besides the BKL.
//!
//! ## Why a spinlock and not the sleeping mutex
//!
//! Two independent reasons, and either alone would settle it. The lazy PLT
//! resolver runs in SVC/exception context, where `RankedMutex` refuses to block
//! (and a nested SVC would HardFault anyway); and yielding the CPU with the heap
//! invariant half-updated is the exact failure the lock exists to prevent. Rank
//! 90 is inner to every sleeping lock in the hierarchy for precisely this
//! reason.
//!
//! ## What changed
//!
//! The previous implementation -- two of them, one in Zig for mps2/mps3 and one
//! in C for the rp2350 -- was a PRIMASK nesting counter. That is correct against
//! this core's own interrupts and provides nothing at all against a second core.
//! It is now a real lock word underneath the same nesting counter, so it does
//! both, and there is one implementation instead of two.

const std = @import("std");

const locks = @import("../../sync/locks.zig");

/// Rank 90: inner to every sleeping lock, outer only to `console` -- which is
/// what lets the allocator log without inverting the hierarchy.
var lock: locks.RecursiveRanked(.kheap) = .{};

/// `__malloc_lock`. Exported under a stable C name because the rp2350 build has
/// to define `__malloc_lock` from a C object (link-order: the pico-sdk pulls
/// newlib's strong `mlock.o` in before the Zig compilation unit is scanned, so
/// the override must resolve from an object linked ahead of `libc_nano.a`).
/// That C file forwards here rather than carrying a second copy of the logic.
pub export fn yasos_kheap_lock() callconv(.c) void {
    lock.lock_irqsave();
}

pub export fn yasos_kheap_unlock() callconv(.c) void {
    lock.unlock_irqrestore();
}

/// Whether this context holds the kernel heap lock.
///
/// For `assert_held` at the head of the allocator's own accounting, which is
/// mutated under the same lock but through a different entry point.
pub fn held_by_current() bool {
    return lock.held_by_current();
}

pub fn assert_held() void {
    if (!locks.checked) return;
    if (!lock.held_by_current()) {
        @panic("kernel heap accounting touched without the heap lock");
    }
}

const testing = std.testing;

test "Sync.KernelHeapLock.NestsTheWayReallocNeeds" {
    locks.reset();
    defer locks.reset();

    // newlib's realloc takes the lock and then calls _malloc_r, which takes it
    // again. A non-recursive lock deadlocks the kernel heap on the first
    // realloc; this is that exact sequence.
    yasos_kheap_lock();
    try testing.expect(held_by_current());
    yasos_kheap_lock();
    assert_held();
    yasos_kheap_unlock();
    // Still held: the outer realloc has not finished.
    try testing.expect(held_by_current());
    yasos_kheap_unlock();
    try testing.expect(!held_by_current());
    try testing.expectEqual(@as(u16, 0), locks.held_ranks());
}

test "Sync.KernelHeapLock.IsInnerToTheSleepingLocks" {
    locks.reset();
    defer locks.reset();

    // The ordering that matters: a filesystem operation may allocate, so `fs`
    // (20) must be takeable before `kheap` (90) and never the other way. If the
    // ranks were reversed, every allocation inside a filesystem call would be a
    // lock-order violation.
    var fs = locks.Ranked(.fs){};
    const flags = fs.lock_irqsave();
    yasos_kheap_lock();
    yasos_kheap_unlock();
    fs.unlock_irqrestore(flags);
    try testing.expectEqual(@as(u16, 0), locks.held_ranks());
}
