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

const std = @import("std");

const config = @import("config");

// True only when building for QEMU's mps2-an505 machine, whose launch scripts
// enable ARM semihosting (`-semihosting-config enable=on`). On real silicon a
// semihosting BKPT with no debugger attached just escalates back into a fault,
// so the exit helpers below are gated to this target and compile to nothing
// elsewhere.
const is_emulated = std.mem.eql(u8, config.board.board, "qemu_mps2_an505");

// ARM semihosting SYS_EXIT_EXTENDED: r0 = op, r1 -> {reason, exit_status}.
// Unlike plain SYS_EXIT (0x18), the extended form lets us hand QEMU an
// arbitrary process exit code instead of just "ok"/"error".
const sys_exit_extended: usize = 0x20;
const adp_stopped_application_exit: usize = 0x20026;

// Terminate the QEMU emulator via a semihosting call, passing `code` through as
// the host process exit status. Never returns: QEMU stops the machine on the
// BKPT, and the spin loop is only a guard in case semihosting is disabled.
pub fn semihosting_exit(code: u32) noreturn {
    const block = [2]usize{ adp_stopped_application_exit, code };
    while (true) {
        asm volatile (
            \\ bkpt 0xAB
            :
            : [op] "{r0}" (sys_exit_extended),
              [blk] "{r1}" (@intFromPtr(&block)),
            : .{ .memory = true }
        );
    }
}

// Auto-exit the emulator when running under QEMU; a no-op on real hardware so
// the caller falls through to whatever halt behaviour it already had.
pub fn exit_if_emulated(code: u32) void {
    if (comptime is_emulated) {
        semihosting_exit(code);
    }
}

pub fn dump_stack_trace(log: anytype, address: usize) void {
    var index: usize = 0;
    var stack = std.debug.StackIterator.init(address, @frameAddress());

    while (stack.next()) |return_address| : (index += 1) {
        log.err("  {d: >3}: 0x{X:0>8}", .{ index, if (return_address > 0) return_address - 1 else return_address });
    }
}

pub const max_stack_depth: usize = 16;

pub fn is_valid_stack_ptr(addr: usize) bool {
    // SRAM: 0x20000000 - 0x2005FFFF, PSRAM: 0x11000000 - 0x117FFFFF
    return (addr >= 0x11000000 and addr < 0x11800000) or
        (addr >= 0x20000000 and addr < 0x20060000);
}

pub fn get_stack_trace_depth(address: usize) usize {
    var index: usize = 0;
    var stack = std.debug.StackIterator.init(address, @frameAddress());
    while (index < max_stack_depth) : (index += 1) {
        if (!is_valid_stack_ptr(stack.fp)) break;
        if (stack.next() == null) break;
    }
    return index;
}
