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

// Where a lock or an atomic is allowed to live. On the RP2350 the global
// exclusive monitor covers internal SRAM but not the PSRAM window at 0x11000000,
// and `ACTLR.EXTEXCLALL` (source/arch/armv8-m/mpu.zig) routes every exclusive
// through it. So an exclusive store to PSRAM never succeeds: any LDREX/STREX
// retry loop there -- every `@atomicRmw` -- spins forever, with nothing
// contending. The process memory pool's tier 1 is PSRAM, so anything reachable
// from process-allocated memory is suspect.
//
// The check walks the board's memory layout, so it belongs at construction,
// never on an acquire path.

const std = @import("std");

const hal = @import("hal");

/// Whether `address` may hold a lock or an atomic, given a board memory layout.
/// `layout` is a slice of anything carrying `memory_type`, `start_address` and
/// `size`, so the rule can be tested against a synthetic board. An address in no
/// known region is accepted; only a region reported as PSRAM is a refusal.
pub fn is_coherent(address: usize, layout: anytype) bool {
    for (layout) |region| {
        if (region.memory_type != .PSRAM) continue;
        if (region.size == 0) continue;
        if (address >= region.start_address and address < region.start_address + region.size) {
            return false;
        }
    }
    return true;
}

/// `is_coherent` against the running board.
pub fn is_coherent_address(address: usize) bool {
    return is_coherent(address, hal.memory.get_memory_layout());
}

/// Panic if a sync object is being constructed somewhere its exclusives do not
/// work. Compiled out when safety is off. Call it from the constructor of
/// anything holding an allocated `SpinLock` or `Atomic` -- never from `lock()`.
pub fn assert_coherent(pointer: *const anyopaque) void {
    if (!std.debug.runtime_safety) return;
    if (!is_coherent_address(@intFromPtr(pointer))) {
        @panic("sync: object placed in PSRAM, where exclusives are not covered by the global monitor");
    }
}

const testing = std.testing;

const TestRegion = struct {
    memory_type: enum { SRAM, PSRAM },
    start_address: usize,
    size: usize,
};

fn test_layout() [3]TestRegion {
    return .{
        .{ .memory_type = .SRAM, .start_address = 0x2000_0000, .size = 0x1000 },
        .{ .memory_type = .PSRAM, .start_address = 0x1100_0000, .size = 0x8000 },
        // A board with no PSRAM fitted reports the region with size 0; that must
        // not turn address 0 into a refusal.
        .{ .memory_type = .PSRAM, .start_address = 0, .size = 0 },
    };
}

test "Sync.Placement.RejectsAddressesInsidePsram" {
    const layout = test_layout();
    try testing.expect(!is_coherent(0x1100_0000, &layout));
    try testing.expect(!is_coherent(0x1100_4000, &layout));
    try testing.expect(!is_coherent(0x1100_7fff, &layout));
}

test "Sync.Placement.AcceptsSramAndTheAddressJustPastPsram" {
    const layout = test_layout();
    try testing.expect(is_coherent(0x2000_0000, &layout));
    try testing.expect(is_coherent(0x2000_0ff0, &layout));
    // Exclusive upper bound: the first byte after the region is not in it.
    try testing.expect(is_coherent(0x1100_8000, &layout));
    try testing.expect(is_coherent(0x10ff_ffff, &layout));
}

test "Sync.Placement.IgnoresUnpopulatedAndUnknownRegions" {
    const layout = test_layout();
    // A board without PSRAM must not have every low address refused.
    try testing.expect(is_coherent(0, &layout));
    // Not in any region the board described: the host case.
    try testing.expect(is_coherent(0x8000_0000, &layout));
    try testing.expect(is_coherent(0, @as([]const TestRegion, &.{})));
}
