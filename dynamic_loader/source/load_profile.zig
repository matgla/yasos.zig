//
// load_profile.zig
//
// Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

//! Temporary load-phase accounting.
//!
//! The loader is a standalone package with no clock of its own, so the kernel
//! installs one here. With the hook null -- every build that does not ask for
//! it -- each probe is a null check and the accumulators stay zero.
//!
//! `children` is inclusive of the recursive child loads; every other bucket is
//! exclusive of them, but note the accumulators are global, so a bucket sums
//! that phase across the parent module *and* all of its children.

pub var time_us_hook: ?*const fn () u64 = null;

pub const Phase = enum(usize) {
    parse,
    children,
    shared_data,
    process_data_alloc,
    process_data_copy,
    init_relocate,
    symbol_relocations,
    local_relocations,
    data_relocations,
    copy_relocations,
};

pub var phase_us: [@typeInfo(Phase).@"enum".fields.len]u64 = @splat(0);

pub inline fn now_us() u64 {
    return if (time_us_hook) |f| f() else 0;
}

pub inline fn account(phase: Phase, start: u64) void {
    if (time_us_hook != null) phase_us[@intFromEnum(phase)] += now_us() - start;
}

pub fn reset() void {
    phase_us = @splat(0);
}
