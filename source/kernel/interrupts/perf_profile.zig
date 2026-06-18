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
const c = @import("libc_imports").c;

pub const enabled = if (@hasDecl(config.instrumentation, "perf_profiling")) config.instrumentation.perf_profiling else false;

// Emitted at `.err` so the line reaches the serial console (only err/warn do)
// and, crucially, so the smoke harness filters it out of parsed command output
// via its LOG_PREFIXES list ("[ERR]"/...). The raw per-test serial capture still
// records it, so `grep '\[ERR\]\[tprof\]'` recovers the timings. Using the `# `
// comment convention instead would leak into every command's output parsing
// (sha256sum hash reads, run-output validation) and break unrelated tests.
const tprof_log = std.log.scoped(.tprof);

/// Emit a profiling line (prefixed `[ERR][tprof]`) used to separate dynamic-load
/// time from real execution time. Compiles to a no-op unless perf profiling is
/// enabled, so production builds pay nothing.
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;
    tprof_log.err(fmt, args);
}

const DEMCR: *volatile u32 = @ptrFromInt(0xE000EDFC);
const DWT_CTRL: *volatile u32 = @ptrFromInt(0xE0001000);
const DWT_CYCCNT: *volatile u32 = @ptrFromInt(0xE0001004);
const TRCENA_BIT: u32 = 1 << 24;
const CYCCNTENA_BIT: u32 = 1;

const SYSCALL_COUNT = c.SYSCALL_COUNT;

var call_counts: [SYSCALL_COUNT]u32 = [_]u32{0} ** SYSCALL_COUNT;
var total_cycles: [SYSCALL_COUNT]u32 = [_]u32{0} ** SYSCALL_COUNT;
var max_cycles: [SYSCALL_COUNT]u32 = [_]u32{0} ** SYSCALL_COUNT;

pub fn init() void {
    if (!enabled) return;
    // Enable DWT cycle counter
    DEMCR.* |= TRCENA_BIT;
    DWT_CYCCNT.* = 0;
    DWT_CTRL.* |= CYCCNTENA_BIT;
}

pub inline fn read_cycles() u32 {
    return DWT_CYCCNT.*;
}

pub fn record(number: u32, elapsed: u32) void {
    if (number >= SYSCALL_COUNT) return;
    call_counts[number] +|= 1;
    total_cycles[number] +|= elapsed;
    if (elapsed > max_cycles[number]) {
        max_cycles[number] = elapsed;
    }
}

pub fn dump(entries: [*]volatile c.perf_syscall_entry, max_entries: usize, num_entries: *volatile i32) void {
    var written: usize = 0;
    for (0..SYSCALL_COUNT) |i| {
        if (call_counts[i] == 0) continue;
        if (written >= max_entries) break;
        entries[written] = .{
            .syscall_id = @intCast(i),
            .call_count = call_counts[i],
            .total_cycles = total_cycles[i],
            .max_cycles = max_cycles[i],
        };
        written += 1;
    }
    num_entries.* = @intCast(written);
}

pub fn reset() void {
    for (0..SYSCALL_COUNT) |i| {
        call_counts[i] = 0;
        total_cycles[i] = 0;
        max_cycles[i] = 0;
    }
}
