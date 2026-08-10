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

//! One lock for all of FatFs, permanently.
//!
//! FatFs is built `FF_FS_REENTRANT 0`, `FF_FS_LOCK 0`, `FF_USE_LFN 1` -- a
//! combination ffconf itself documents as "Always NOT thread-safe". `LfnBuf` is
//! a single 256-entry scratch buffer written by every name comparison in every
//! directory walk, and `FatFs[]`, `Fsid` and `CurrVol` are all file-scope state
//! in `ff.c`. Making it concurrent is not a goal and never will be; serialising
//! it is.
//!
//! ## This closes a hole that is open today, on one core
//!
//! It would be easy to assume the existing `block_context_switch` windows
//! already cover this. They do not. `sys_read` and `sys_write` deliberately
//! release the window *before* touching the file:
//!
//! ```zig
//! const maybe_handle = process.get_file_handle(...);
//! kernel.process.unblock_context_switch();
//! if (maybe_handle) |handle| { result_out.* = file.interface.read(destination); }
//! ```
//!
//! so every FatFs read and write already runs preemptible. Two processes doing
//! file I/O can already interleave inside `ff.c` and scribble over each other's
//! `LfnBuf`. That it has not obviously broken is a property of the workload --
//! the shell spends almost all of its time blocked in `waitpid` while one child
//! runs -- not of the code.
//!
//! ## Why a sleeping mutex and not a spinlock
//!
//! Because it is held across SD card I/O. A spinlock here would sit in `cpsid i`
//! for milliseconds, and `hal/.../uart_driver.zig:51-59` documents a ~93 µs
//! RX-FIFO overrun window that every masked section has to fit inside. It is
//! rank `fs` (20), outside every spinlock in the hierarchy, which is what
//! `sync/locks.zig` encodes with "never take a sleeping mutex while holding a
//! spinlock".
//!
//! ## Where it is taken
//!
//! At the outermost FatFs boundary only -- the `IFileSystem`, `IFile` and
//! `IDirectory` methods -- and never on the internal constructors
//! (`FatFsFile.create_node`, `FatFsDirectory.create_node`), which are reached
//! only from `FatFs.get` with the lock already held. The mutex is deliberately
//! **not** recursive, so getting that wrong panics by name instead of hanging.

const kernel = @import("kernel");

/// The single FatFs lock. One instance for the whole system, matching the one
/// `global_fs` it protects.
pub var lock: kernel.sync.RankedMutex(.fs) = .{};

/// `lock.lock()` paired with a `defer`, as the entry points use it.
pub inline fn acquire() void {
    lock.lock();
}

pub inline fn release() void {
    lock.unlock();
}
