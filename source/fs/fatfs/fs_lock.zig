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

// One lock for all of FatFs, permanently. It is built `FF_FS_REENTRANT 0`,
// `FF_FS_LOCK 0`, `FF_USE_LFN 1`, which ffconf documents as "Always NOT
// thread-safe": `LfnBuf` is one 256-entry scratch buffer written by every name
// comparison in every directory walk, and `FatFs[]`, `Fsid` and `CurrVol` are
// file-scope state in `ff.c`. Making it concurrent is not a goal; serialising it
// is.
//
// A sleeping mutex, not a spinlock, because it is held across SD card I/O -- a
// spinlock would sit in `cpsid i` for milliseconds against a ~93 us RX-FIFO
// overrun window. Rank `fs` (20), outside every spinlock in the hierarchy.
//
// Taken at the outermost FatFs boundary only -- the `IFileSystem`, `IFile` and
// `IDirectory` methods -- never on the internal constructors, which are reached
// from `FatFs.get` with the lock already held. Not recursive, so getting that
// wrong panics by name instead of hanging.

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
