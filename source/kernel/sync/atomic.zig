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

// `std.atomic.Value(T)` plus a comptime refusal of any `T` the CPU cannot do
// inline. Prefer it over `std.atomic.Value` everywhere in the kernel.

const std = @import("std");

const arch = @import("arch");

/// The widest `T` an `Atomic(T)` may hold, in bits.
pub const lock_free_bits: u16 = arch.atomic.lock_free_bits;

/// Whether `T` is one machine word by construction on any target. The exemption
/// that lets the width rule stay at the device's 32 bits in a 64-bit host build.
/// Slices and `allowzero` optionals are two words and fall through to the rule.
pub fn is_machine_word(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size != .slice,
        .optional => |optional| switch (@typeInfo(optional.child)) {
            // `?*T` folds its tag into the null representation and stays one
            // word; `?*allowzero T` cannot, and does not.
            .pointer => |pointer| pointer.size != .slice and !pointer.attrs.@"allowzero",
            else => false,
        },
        else => false,
    };
}

/// Width of the exclusive access an `Atomic(T)` would need, in bits. Storage
/// size rather than `@bitSizeOf`, which is what the exclusive instruction
/// operates on and is defined for the two-word shapes this must reject.
pub fn access_bits(comptime T: type) u16 {
    return @sizeOf(T) * 8;
}

/// Whether `T` gets a lock-free atomic on a `limit`-bit CPU. Parameterised on
/// the limit so the rule is testable -- `Atomic(u64)` is a compile error.
pub fn fits_lock_free(comptime T: type, limit: u16) bool {
    if (is_machine_word(T)) return true;
    return access_bits(T) <= limit;
}

/// A lock-free atomic cell. The API is `std.atomic.Value(T)`'s, with an explicit
/// `std.builtin.AtomicOrder` at every site and no default ordering.
pub fn Atomic(comptime T: type) type {
    if (!fits_lock_free(T, lock_free_bits)) {
        @compileError(std.fmt.comptimePrint(
            "Atomic({s}) needs a {d}-bit exclusive access, but this target is " ++
                "lock-free only up to {d} bits. A wider atomic does not fault -- it " ++
                "silently becomes an __atomic_* libcall that takes a global lock, " ++
                "which is neither lock-free nor safe from an exception handler. " ++
                "Make the value per-CPU and sum it, or narrow it.",
            .{ @typeName(T), access_bits(T), lock_free_bits },
        ));
    }
    return std.atomic.Value(T);
}

const testing = std.testing;

test "Sync.Atomic.AcceptsEveryWidthTheCoreCanDoInline" {
    var counter = Atomic(u32).init(0);
    _ = counter.fetchAdd(1, .monotonic);
    try testing.expectEqual(@as(u32, 1), counter.load(.monotonic));

    var flag = Atomic(bool).init(false);
    flag.store(true, .release);
    try testing.expect(flag.load(.acquire));

    const State = enum(u8) { ready, running };
    var state = Atomic(State).init(.ready);
    try testing.expectEqual(null, state.cmpxchgStrong(.ready, .running, .acq_rel, .monotonic));
    try testing.expectEqual(State.running, state.load(.monotonic));

    var value: u32 = 7;
    var pointer = Atomic(?*u32).init(null);
    pointer.store(&value, .release);
    try testing.expectEqual(@as(u32, 7), pointer.load(.acquire).?.*);
}

test "Sync.Atomic.RejectsWidthsThatWouldBecomeALibcall" {
    // `Atomic(u64)` is a compile error, so the rule itself is what gets tested.
    try testing.expect(fits_lock_free(u32, lock_free_bits));
    try testing.expect(!fits_lock_free(u64, lock_free_bits));
    try testing.expect(!fits_lock_free(i64, lock_free_bits));
    try testing.expect(!fits_lock_free(f64, lock_free_bits));

    // The limit is the device's on every target: an atomic that compiles in
    // `zig build test` has to compile for the M33.
    try testing.expectEqual(@as(u16, 32), lock_free_bits);
}

test "Sync.Atomic.PointersStayLockFreeOnASixtyFourBitHost" {
    try testing.expect(is_machine_word(*u32));
    try testing.expect(is_machine_word(?*u32));
    try testing.expect(is_machine_word([*]u8));
    try testing.expect(fits_lock_free(*u32, lock_free_bits));
    try testing.expect(fits_lock_free(?*u32, lock_free_bits));

    // Two-word shapes must not slip through the exemption.
    try testing.expect(!is_machine_word([]u8));
    try testing.expect(!is_machine_word(?[]u8));
    try testing.expect(!is_machine_word(?*allowzero u32));
    try testing.expect(!fits_lock_free([]u8, lock_free_bits));
}

test "Sync.Atomic.AccessBitsFollowsTheExclusiveTheOperationNeeds" {
    try testing.expectEqual(@as(u16, 8), access_bits(u8));
    try testing.expectEqual(@as(u16, 16), access_bits(u16));
    try testing.expectEqual(@as(u16, 32), access_bits(u32));
    try testing.expectEqual(@as(u16, 64), access_bits(u64));
}
