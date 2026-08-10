//
// file_log.zig
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

// Persistent kernel log on the SD card (/root/logs/kernel.log).
//
// Enabled by CONFIG_INSTRUMENTATION_LOG_TO_SD. Design constraints learned the
// hard way (a synchronous per-line mirror bus-faulted the SDIO PIO/DMA driver
// when driven from the dynamic loader's context at boot):
//   * The RP2350 SDIO driver is PIO+DMA and NON-REENTRANT; FatFs is likewise
//     not reentrant. SD I/O must never run concurrently with, or nested inside,
//     another SD/FatFs operation.
//   * Kernel log lines are emitted from arbitrary contexts (early boot, the
//     unprivileged in-process dynamic loader, IRQs). Touching the SD card from
//     those contexts is unsafe.
//
// So: the log path only ever appends to a RAM ring buffer (cheap, context- and
// IRQ-safe). All SD I/O is DEFERRED to drain(), which is called from the FS
// read/write syscalls — a context that already performs SD I/O safely and
// serialized (process file I/O). Consequences:
//   * Zero SD I/O at boot: lines buffer until the first FS syscall drains them,
//     so the boot-time loader-context fault window no longer exists.
//   * The SD file is opened lazily on the first drain (also a safe context),
//     not at init(), so rotation/create never run from boot context either.
//   * The buffer is a ring: on overflow the oldest bytes are dropped so the
//     most recent log (what matters near a crash) is always retained.

const std = @import("std");

const c = @import("libc_imports").c;
const config = @import("config");

const kernel = @import("kernel.zig");

const log = std.log.scoped(.file_log);

// Compile-time master switch (Kconfig: CONFIG_INSTRUMENTATION_LOG_TO_SD).
const persist_to_sd = config.instrumentation.log_to_sd;

const log_dir = "/root/logs";
const log_path = "/root/logs/kernel.log";
const prev_path = "/root/logs/kernel.prev.log";

const buffer_size = 512;

var enabled: bool = false;
var opened: bool = false; // SD file opened lazily from a safe (drain) context
var node: ?kernel.fs.Node = null;

// Circular byte buffer. `head` is the next write position, `count` the number
// of valid bytes ending at `head` (oldest at head-count, wrapping).
//
// Aligned to the SD block size (512). When FatFs takes its whole-sector
// fast path it hands the caller's buffer straight to disk_write -> the RP2350
// SDIO driver, which DMAs directly only when the buffer is 4-byte aligned and
// otherwise falls back to a per-block bounce @memcpy (mmc_sdio.write_sdio_data).
// A 512-aligned base keeps the drain spans on the DMA-direct path.
var ring: [buffer_size]u8 align(512) = undefined;
var head: usize = 0;
var count: usize = 0;
var dropped: usize = 0;

var appending: bool = false; // re-entrancy guard for the log sink
var draining: bool = false; // set while SD I/O is in flight in drain()

// Enable the RAM sink. No SD I/O here — the file is opened lazily on the first
// drain() from a safe context. Call once after /root is mounted. The kernel log
// front-end (kernel_stdout_log) feeds lines in via append(); see is_enabled().
pub fn init() void {
    if (!persist_to_sd) return;
    enabled = true;
}

// Whether the file log is active. kernel_stdout_log uses this to decide whether
// info/debug lines have a sink (they are kept off the blocking serial console).
pub fn is_enabled() bool {
    return enabled;
}

// Append a pre-formatted log line to the RAM ring (drained to SD later from a
// safe context). Cheap, context- and IRQ-safe; no-op when disabled.
pub fn append(data: []const u8) void {
    _ = sink(undefined, data) catch {};
}

// Stop buffering/draining. Called from the fault handler so the panic path
// never issues blocking SD I/O.
pub fn disable() void {
    enabled = false;
}

export fn file_log_disable() void {
    disable();
}

// Secondary stdout sink: append bytes to the ring buffer. Safe from any
// context — pure memory writes guarded against re-entrancy. While drain() is
// performing SD I/O we drop (and count) new bytes rather than mutate the buffer
// underneath it.
fn sink(_: *const anyopaque, data: []const u8) anyerror!usize {
    if (!enabled or appending or draining) {
        if (draining) dropped +%= data.len;
        return data.len;
    }
    appending = true;
    defer appending = false;
    for (data) |b| {
        ring[head] = b;
        head = (head + 1) % buffer_size;
        if (count < buffer_size) {
            count += 1;
        } else {
            dropped +%= 1; // overwrote the oldest byte
        }
    }
    return data.len;
}

// Open (rotating) the SD log file. Runs only from drain() (safe context).
fn open_files() void {
    const vfs = kernel.fs.get_vfs();
    vfs.mkdir(log_dir, 0o755) catch {}; // ignore: may already exist
    rotate();
    vfs.create(log_path, 0o644) catch return;
    node = kernel.fs.get_ivfs().interface.get(log_path) catch return;
    opened = true;
}

// Copy the previous boot's kernel.log to kernel.prev.log so a crash+reset does
// not lose the run that produced it. Best-effort.
fn rotate() void {
    var src = (kernel.fs.get_ivfs().interface.get(log_path) catch return);
    defer src.delete();
    var src_file = src.as_file() orelse return;

    kernel.fs.get_vfs().create(prev_path, 0o644) catch return;
    var dst = kernel.fs.get_ivfs().interface.get(prev_path) catch return;
    defer dst.delete();
    var dst_file = dst.as_file() orelse return;

    var copy: [256]u8 = undefined;
    while (true) {
        const n = src_file.interface.read(&copy);
        if (n <= 0) break;
        _ = dst_file.interface.write(copy[0..@intCast(n)]);
    }
    _ = dst_file.interface.sync();
}

// Flush the buffered log to the SD card. MUST be called only from a context
// that is safe for SD I/O and not nested inside another FatFs operation — i.e.
// the FS read/write syscalls, after their own file op has completed. Cheap when
// there is nothing buffered.
pub fn drain() void {
    if (!persist_to_sd) return;
    if (!enabled or draining or count == 0) return;
    draining = true;
    defer draining = false;
    // No context-switch window. This used to block them "so no process FS op
    // can interleave with ours (FatFs is not reentrant)" -- which is now
    // `fs_lock`'s job, taken by the FatFs calls below and held across the SD
    // write. Refusing to be preempted for the duration of a card write was a
    // very expensive way to get exclusion, and it excluded nothing on a second
    // core.
    //
    // `draining` above still guards re-entry from *this* context.

    if (!opened) {
        open_files();
        if (!opened) return;
    }
    if (node) |*n| {
        if (n.as_file()) |file_const| {
            var file = file_const;
            // Write the ring oldest-first. It may wrap, so emit up to two spans.
            const start = (head + buffer_size - count) % buffer_size;
            if (start + count <= buffer_size) {
                _ = file.interface.write(ring[start .. start + count]);
            } else {
                const first = buffer_size - start;
                _ = file.interface.write(ring[start..buffer_size]);
                _ = file.interface.write(ring[0 .. count - first]);
            }
            _ = file.interface.sync();
        }
    }
    count = 0;
    head = 0;
}

export fn file_log_drain() void {
    drain();
}
