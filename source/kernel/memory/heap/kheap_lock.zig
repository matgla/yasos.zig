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

// The kernel heap lock -- `__malloc_lock` / `__malloc_unlock`, rank `kheap`.
// The kernel heap is newlib malloc: the dynamic loader allocates through it
// during execve and lazy PLT resolve, and so does every kernel structure.
//
// Recursive because newlib's API forces it: `realloc` takes `__malloc_lock` and
// then calls the also-locking `_malloc_r` / `_free_r`.
//
// A spinlock, not the sleeping mutex, for two independent reasons: the lazy PLT
// resolver runs in exception context where `RankedMutex` refuses to block, and
// yielding with the heap invariant half-updated is the failure the lock exists
// to prevent. Rank 90 is inner to every sleeping lock for that reason.

const std = @import("std");

const locks = @import("../../sync/locks.zig");

/// Rank 90: inner to every sleeping lock, outer only to `console` -- which is
/// what lets the allocator log without inverting the hierarchy.
var lock: locks.RecursiveRanked(.kheap) = .{};

/// `__malloc_lock`. Exported under a stable C name because the rp2350 build must
/// define `__malloc_lock` from a C object linked ahead of `libc_nano.a` -- the
/// pico-sdk pulls newlib's strong `mlock.o` in before the Zig unit is scanned.
/// That C file forwards here rather than carrying a second copy.
pub export fn yasos_kheap_lock() callconv(.c) void {
    lock.lock_irqsave();
}

pub export fn yasos_kheap_unlock() callconv(.c) void {
    lock.unlock_irqrestore();
}

/// Whether this context holds the kernel heap lock. For `assert_held` in the
/// allocator's own accounting, which is mutated under the same lock through a
/// different entry point.
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

    // A filesystem operation may allocate, so `fs` (20) must be takeable before
    // `kheap` (90) and never the other way.
    var fs = locks.Ranked(.fs){};
    const flags = fs.lock_irqsave();
    yasos_kheap_lock();
    yasos_kheap_unlock();
    fs.unlock_irqrestore(flags);
    try testing.expectEqual(@as(u16, 0), locks.held_ranks());
}
