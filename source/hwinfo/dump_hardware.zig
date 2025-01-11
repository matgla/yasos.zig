//
// dump_hardware.zig
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

const cpu = @import("hal").cpu;

pub const DumpHardware = struct {
    pub fn print_hardware(log: anytype) void {
        log.print("-----------------------------------------\n", .{});
        log.print("|   CPU: {s: <10}  FREQ: {s: <12} |\n", .{ cpu.name(), format_frequency(cpu.frequency()) });
        log.print("| Cores: {d: <2}                             |\n", .{cpu.number_of_cores()});
        log.print("-----------------------------------------\n", .{});
    }

    fn format_frequency(freq: u64) []const u8 {
        var buffer: [8]u8 = undefined;
        if (freq >= 1000000000000) {
            return std.fmt.bufPrint(&buffer, "{d: <4} ---", .{freq / 1000000000000}) catch buffer[0..];
        } else if (freq >= 1000000000) {
            return std.fmt.bufPrint(&buffer, "{d: <4} GHz", .{freq / 1000000000}) catch buffer[0..];
        } else if (freq >= 1000000) {
            return std.fmt.bufPrint(&buffer, "{d: <4} MHz", .{freq / 1000000}) catch buffer[0..];
        } else if (freq >= 1000) {
            return std.fmt.bufPrint(&buffer, "{d: <4} KHz", .{freq / 1000}) catch buffer[0..];
        } else {
            return std.fmt.bufPrint(&buffer, "{d: <4} Hz", .{freq}) catch buffer[0..];
        }

        return buffer;
    }
};

test "format frequency" {
    try std.testing.expect(DumpHardware.format_frequency(0), "0 MHz");
}
