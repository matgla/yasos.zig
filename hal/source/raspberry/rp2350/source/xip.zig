//
// xip.zig
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

/// The RP2350's XIP cache keeps two performance counters that nothing else in
/// this tree claims: an access counter and a hit counter. They are the only
/// direct evidence available for whether code is waiting on the core or on QMI
/// fetches, since every instruction outside SRAM and every PSRAM data access
/// crosses this cache.
///
/// Both count *all* XIP traffic — flash (CS0) and PSRAM (CS1), instruction and
/// data, cacheable and not — through one pair of registers. There is no way to
/// separate the two chip selects here, so a hit rate read off these counters is
/// the whole XIP window's, not the instruction stream's alone.
const XipCtrl = extern struct {
    ctrl: u32,
    _reserved: u32,
    stat: u32,
    /// Increments on each access serviced from cached data. Saturating; write
    /// any value to clear.
    ctr_hit: u32,
    /// Increments on each XIP access whether or not it hit, including
    /// non-cacheable ones. Saturating; write any value to clear.
    ctr_acc: u32,
};

const xip_ctrl: *volatile XipCtrl = @ptrFromInt(0x400c8000);

/// What one read of the counter pair saw. Both fields are the count since the
/// previous `sample_and_clear`, so a caller that wants a total has to keep one
/// itself — see `saturation_value` for why leaving it to the hardware does not
/// work over a long window.
pub const Counters = struct {
    hit: u32 = 0,
    acc: u32 = 0,
};

/// Both counters saturate here rather than wrapping, so a sample that comes
/// back pinned at this value has lost an unknown number of accesses and cannot
/// be added to a total. At 618 MHz and one access per cycle it takes about 7
/// seconds to reach, which is why the counters have to be drained on a timer
/// and not just read at the ends of whatever is being measured.
pub const saturation_value: u32 = 0xffff_ffff;

/// Read both counters and reset them, returning what the window held.
///
/// The two reads are not simultaneous, so the handful of accesses between them
/// — this function's own instruction fetches, if it is running XIP — land in
/// `acc` while their hits land in the *next* window's `hit`. That biases the
/// hit rate down by order ten accesses per call, against the hundreds of
/// thousands a millisecond of execution produces.
pub fn sample_and_clear() Counters {
    const sample = Counters{
        .hit = xip_ctrl.ctr_hit,
        .acc = xip_ctrl.ctr_acc,
    };
    xip_ctrl.ctr_hit = 0;
    xip_ctrl.ctr_acc = 0;
    return sample;
}
