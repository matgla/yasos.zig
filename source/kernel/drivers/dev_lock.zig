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

// The block-device lock: rank `dev` (30), inner to `fs` (20).
//
// It guards the seek position, which lives in the device file object and is
// shared by every handle to it. Callers all do `seek` then `read`, and two of
// those interleaved means the first read returns the second one's data. `fs`
// does not cover it: romfs drives the same device file directly, and two
// filesystems never hold one `fs` lock.
//
// A sleeping mutex, not the PRIMASK section the FatFs disk wrapper used to keep
// its seek and transfer together: a multi-sector SD command masks for
// milliseconds, against a ~93 us RX-FIFO overrun window.
//
// One global instance rather than one per device, for now: it cannot deadlock
// against itself through an ordering mistake, and on a single core it is no
// coarser than the interrupt mask it replaces. Taken at the outermost device
// boundary only -- the mutex is not recursive, so an inner helper that takes it
// again panics by name.

const kernel = @import("../kernel.zig");

pub var lock: kernel.sync.RankedMutex(.dev) = .{};

pub inline fn acquire() void {
    lock.lock();
}

pub inline fn release() void {
    lock.unlock();
}
