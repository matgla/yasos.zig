//
// arch.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//

const std = @import("std");

const config = @import("config");

pub const process = @import("process.zig");
pub const irq_handlers = @import("irq_handlers.zig");
pub const panic = @import("panic.zig");
pub const HardwareProcess = @import("process.zig").HostProcess;

/// Kept byte-for-byte in step with `source/arch/ut/arch.zig`; see the commentary
/// there for why the host reports the *device's* lock-free width.
pub const atomic = struct {
    pub const lock_free_bits: u16 = 32;

    pub inline fn clear_exclusive() void {}
};

pub const sync = struct {
    pub inline fn save_and_disable_interrupts() usize {
        return 0;
    }

    pub inline fn restore_interrupts(primask: usize) void {
        _ = primask;
    }

    pub inline fn cpu_relax() void {
        std.atomic.spinLoopHint();
    }

    pub inline fn signal_event() void {}

    /// The host has no exception handlers, so nothing can be in one.
    pub inline fn in_handler_mode() bool {
        return false;
    }

    pub inline fn owner_id() u32 {
        return @truncate(std.Thread.getCurrentId());
    }
};

pub fn disable_interrupts() void {}
pub fn enable_interrupts() void {}

/// Compiler barrier only. `@fence` no longer exists in this Zig, and on the
/// hosts this target builds for (x86-64, aarch64 under TSO-ish load/store
/// ordering for the uses here) the reordering that matters is the compiler's.
/// Ordering that has to be real is expressed on the atomic operation itself --
/// see `kernel.sync.Atomic` -- not through a standalone fence.
pub fn memory_barrier_release() void {
    asm volatile ("" ::: .{ .memory = true });
}

pub fn memory_barrier_acquire() void {
    asm volatile ("" ::: .{ .memory = true });
}
