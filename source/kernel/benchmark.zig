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
const hal = @import("hal");

const log = std.log.scoped(.benchmark);

var previous: u64 = 0;

pub fn timestamp(name: []const u8) void {
    const time = hal.time.get_time_us();
    if (previous == 0) {
        previous = time;
        return;
    }
    log.debug("Timepoint '{s}' {d} us, diff: {d}", .{ name, time, time - previous });
    previous = time;
}

test "Benchmark.Timestamp" {
    hal.time.impl.set_time(0);
    timestamp("start");
    hal.time.impl.set_time(10000);
    timestamp("after 10ms sleep");
    hal.time.impl.set_time(20000);
    timestamp("after 20ms sleep");
}
