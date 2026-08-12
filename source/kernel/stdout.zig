//
// kernel_log.zig
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
const vfmt = @import("vfmt.zig");

const board = @import("board");
const arch = @import("arch");
const kernel_sync = @import("sync/sync.zig");
const preempt = @import("sync/preempt.zig");

var stdout: std.Io.Writer = undefined;
var write_callback: ?WriteCallback = null;
var write_context: ?*const anyopaque = null;
var suppressed: bool = false;

// Optional secondary sink (e.g. SD-card file log). It mirrors everything
// written to the primary console. Errors from the secondary are swallowed so a
// failing log file can never break console output.
var secondary_callback: ?WriteCallback = null;
var secondary_context: ?*const anyopaque = null;

pub const WriteCallback = *const fn (self: *const anyopaque, data: []const u8) anyerror!usize;

/// Rank 95, the innermost leaf, and held without masking interrupts: the console
/// is a blocking per-byte UART, so a hundred-byte line is milliseconds and
/// masking across it would blow the ~93 us RX-FIFO budget this device is trying
/// to meet. It therefore excludes the other core, not this core's handlers,
/// which take it if free and write anyway if not -- a garbled panic beats a hung
/// one. A thread can never find it held by a same-core handler, since handlers
/// run to completion, so the blocking path cannot deadlock.
var console_lock: kernel_sync.Ranked(.console) = .{};

/// Take the console if we are allowed to wait for it. Returns whether it was
/// acquired; false means "write anyway, ungoverned".
///
/// In handler context the question is not "is it free" but "is it *mine*". If
/// this core holds it, waiting would hang -- nothing on this core can run to
/// release it -- so garbled output is the better failure. If the *other* core
/// holds it, that core is running and will release, and writing ungoverned is
/// just corruption: two cores' lines interleave mid-token. `held_by_current` is
/// race-free for this, since only this core can make it true.
///
/// Public because `UartFile` -- the `/dev/uart0` node behind every process's
/// fd 1 -- writes straight to the HAL. Anything that emits bytes to the console
/// UART has to come through here.
pub fn console_acquire() bool {
    if (arch.sync.in_handler_mode()) {
        // Ours already -- waiting would be waiting on ourselves.
        if (console_lock.held_by_current()) return false;
        console_lock.lock_no_irq();
        return true;
    }
    // **Preemption off for the duration, and this is the price of not masking
    // interrupts.** Leaving them on is what keeps the RX FIFO serviced, but it
    // also means PendSV can land in the middle of the section -- and PendSV
    // takes `proctable` (rank 50) while this core's held-set still says
    // `console` (rank 95). lockdep is right to call that an inversion rather
    // than bookkeeping noise: the other core can be inside `proctable` waiting
    // for this console, while this core's PendSV waits for that `proctable`.
    //
    //   [ERR][lockdep] lock order violation: taking proctable (rank 50) while
    //                  holding ranks 0x2000
    //     do_context_switch -> ProcessManager.schedule_next
    //
    // Refusing preemption closes it without touching PRIMASK: `do_context_switch`
    // sees the window and records `need_resched` instead of scheduling, and
    // `preempt_enable` below re-pends PendSV. `proctable` is only ever taken in
    // `process_manager.zig`, and the only handler that reaches it is PendSV, so
    // this is the whole edge. Interrupts stay enabled throughout, so the ~93 us
    // RX budget is unaffected -- only the *switch* is deferred, and only for as
    // long as the other core is excluded anyway.
    preempt.preempt_disable();
    console_lock.lock_no_irq();
    return true;
}

pub fn console_release(held: bool) void {
    if (held) console_lock.unlock_no_irq();
    // Mirrors the acquire: thread context always disabled preemption, handler
    // context never did. Every caller pairs the two with `defer`.
    if (!arch.sync.in_handler_mode()) preempt.preempt_enable();
}

fn drain_sink(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = splat;
    _ = io_w;
    if (suppressed) return data[0].len;
    if (write_context == null) return error.WriteFailed;
    if (write_callback) |callback| {
        const written = callback(write_context.?, data[0]) catch return error.WriteFailed;
        if (secondary_callback) |secondary| {
            _ = secondary(secondary_context orelse undefined, data[0][0..written]) catch {};
        }
        return written;
    }
    return error.WriteFailed;
}

pub fn set_output(context: *const anyopaque, writer: WriteCallback) void {
    write_callback = writer;
    write_context = context;
    stdout = std.Io.Writer{
        .vtable = &.{
            .drain = drain_sink,
        },
        .buffer = &.{},
    };
}

pub fn set_secondary_output(context: *const anyopaque, writer: WriteCallback) void {
    secondary_context = context;
    secondary_callback = writer;
}

pub fn clear_secondary_output() void {
    secondary_callback = null;
    secondary_context = null;
}

pub fn get() *std.Io.Writer {
    return &stdout;
}

pub fn print(comptime format: []const u8, args: anytype) void {
    const argv = vfmt.erase(args);
    print_formatted(format, &argv);
}

noinline fn print_formatted(format: []const u8, argv: []const vfmt.Value) void {
    var buf: [256]u8 = undefined;
    const line = vfmt.vprint(&buf, format, argv);
    const held = console_acquire();
    defer console_release(held);
    _ = stdout.write(line) catch return;
}

pub fn write(comptime data: []const u8) void {
    const held = console_acquire();
    defer console_release(held);
    _ = stdout.write(data) catch return;
}

// Like `write` but for runtime byte slices (e.g. a pre-formatted log line).
pub fn write_bytes(data: []const u8) void {
    const held = console_acquire();
    defer console_release(held);
    _ = stdout.write(data) catch return;
}

pub fn suppress(value: bool) void {
    suppressed = value;
}

// Fault-path escape hatch (extern-callable from arch code): a HardFault dump
// must never be swallowed by an active klog_ctl(0) suppression — the
// suppressing process (e.g. `rz` during a zmodem transfer) may be the very
// process that faulted, and it will never run klog_ctl(1) again.
export fn klog_force_enable() void {
    suppressed = false;
}
