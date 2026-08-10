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

//! The block-device lock: rank `dev` (30), inner to `fs` (20).
//!
//! ## What it actually guards
//!
//! Not "the device" in the abstract -- the **seek position**, which lives in the
//! device file object and is shared by everyone holding a handle to it. Every
//! caller does the same thing:
//!
//! ```zig
//! _ = try device.interface.seek(offset, SEEK_SET);
//! _ = device.interface.read(buffer);
//! ```
//!
//! Two of those interleaved and the second seek lands between the first seek
//! and its read, so the first read returns the second one's data. The pair has
//! to be atomic, and neither call can make it so on its own.
//!
//! `fs` does not cover this. FatFs reaches the device with `fs` held, but romfs
//! drives the same shape of device file directly (`romfs/file_reader.zig`), and
//! romfs is a different filesystem -- two filesystems never hold one `fs` lock.
//!
//! ## Why it replaces a PRIMASK section rather than adding to one
//!
//! The FatFs disk wrapper used to keep its seek and transfer together by
//! masking interrupts for the duration. That is correct exclusion and an
//! unacceptable way to get it: the transfer is a multi-sector SD command, so the
//! mask lasts milliseconds, and `hal/.../uart_driver.zig:51-59` documents a
//! ~93 µs RX-FIFO overrun window that every masked section is supposed to fit
//! inside. A sleeping mutex gives the same exclusion with interrupts on.
//!
//! ## One lock, not one per device
//!
//! The plan's table says `dev_lock[dev]`, and per-device is where this ends up.
//! One global instance is the deliberate first step: it cannot deadlock against
//! itself through a lock-ordering mistake between two devices, and on a single
//! core it is no coarser than the interrupt mask it replaces. Split it when
//! there is a second device stack worth the contention.
//!
//! ## Nesting
//!
//! Taken at the outermost device boundary only. The mutex is not recursive, so
//! an inner helper that takes it again panics by name -- which is how the two
//! re-entries in the FatFs wrapper were found rather than hung on.

const kernel = @import("../kernel.zig");

pub var lock: kernel.sync.RankedMutex(.dev) = .{};

pub inline fn acquire() void {
    lock.lock();
}

pub inline fn release() void {
    lock.unlock();
}
