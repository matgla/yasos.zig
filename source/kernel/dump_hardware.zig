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
const vfmt = @import("vfmt.zig");

const cpu = @import("hal").cpu;
const memory = @import("hal").memory;

const kernel = @import("kernel.zig");

pub const DumpHardware = struct {
    pub fn print_hardware() void {
        var buffer: [8]u8 = undefined;
        kernel.stdout.print("---------------------------------------------\n", .{});
        kernel.stdout.print("|   CPU: {s: <10}  FREQ: {s: <12}     |\n", .{
            cpu.name(),
            format_frequency(cpu.frequency(), &buffer),
        });
        kernel.stdout.print("| Cores: {d: <2}                                 |\n", .{
            cpu.number_of_cores(),
        });
        if (cpu.vreg_vsel()) |vsel| {
            const mv = vselToMv(vsel);
            kernel.stdout.print("|  VREG: {d}mV (vsel={d})                     |\n", .{ mv, vsel });
        }
        DumpHardware.print_memory();
        kernel.stdout.print("---------------------------------------------\n", .{});
    }

    pub fn print_memory() void {
        var buffer: [8]u8 = undefined;
        kernel.stdout.print("| Memory layout:                            |\n", .{});
        const layout = memory.get_memory_layout();
        for (layout) |entry| {
            kernel.stdout.print("|  0x{x: <12}  {s: <8} {s: <8} {s: <5}  |\n", .{
                entry.start_address,
                format_size(entry.size, &buffer),
                @tagName(entry.memory_type),
                @tagName(entry.speed),
            });
        }
    }

    fn vselToMv(vsel: u8) u16 {
        // VSEL 0-15: 550 + 50*n mV (linear), above 15 non-linear
        const lut = [_]u16{
            550, 600, 650, 700, 750, 800, 850, 900, // 0-7
            950, 1000, 1050, 1100, 1150, 1200, 1250, 1300, // 8-15
            1350, 1400, 1500, 1600, 1650, 1700, 1800, 1900, // 16-23
            2000, 2100, 2200, 2300, 2400, 2500, 2600, 3300, // 24-31
        };
        return lut[vsel];
    }

    fn format_size(size: u64, buffer: []u8) []const u8 {
        if (size >= 1000000000000) {
            return vfmt.print(buffer, "TB", .{});
        } else if (size >= 1024 * 1024 * 1024) {
            return vfmt.print(buffer, "{d: <4} GB", .{size / 1024 / 1024 / 1024});
        } else if (size >= 1024 * 1024) {
            return vfmt.print(buffer, "{d: <4} MB", .{size / 1024 / 1024});
        } else if (size >= 1024) {
            return vfmt.print(buffer, "{d: <4} KB", .{size / 1024});
        } else {
            return vfmt.print(buffer, "{d: <4} B", .{size});
        }

        return buffer;
    }

    fn format_frequency(freq: u64, buffer: []u8) []const u8 {
        if (freq >= 1000000000000) {
            return vfmt.print(buffer, "{d: <4} ---", .{freq / 1000000000000});
        } else if (freq >= 1000000000) {
            return vfmt.print(buffer, "{d: <4} GHz", .{freq / 1000000000});
        } else if (freq >= 1000000) {
            return vfmt.print(buffer, "{d: <4} MHz", .{freq / 1000000});
        } else if (freq >= 1000) {
            return vfmt.print(buffer, "{d: <4} KHz", .{freq / 1000});
        } else {
            return vfmt.print(buffer, "{d: <4} Hz", .{freq});
        }

        return buffer;
    }
};

test "DumpHardware.FormatFrequency" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0    Hz", DumpHardware.format_frequency(0, &buffer));
    try std.testing.expectEqualStrings("999  Hz", DumpHardware.format_frequency(999, &buffer));
    try std.testing.expectEqualStrings("1    KHz", DumpHardware.format_frequency(1000, &buffer));
    try std.testing.expectEqualStrings("1    KHz", DumpHardware.format_frequency(1500, &buffer));
    try std.testing.expectEqualStrings("1    MHz", DumpHardware.format_frequency(1000000, &buffer));
    try std.testing.expectEqualStrings("2    MHz", DumpHardware.format_frequency(2500000, &buffer));
    try std.testing.expectEqualStrings("1    GHz", DumpHardware.format_frequency(1000000000, &buffer));
    try std.testing.expectEqualStrings("1    GHz", DumpHardware.format_frequency(1250000000, &buffer));
    try std.testing.expectEqualStrings("1    ---", DumpHardware.format_frequency(1000000000000, &buffer));
}

test "DumpHardware.FormatSize" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0    B", DumpHardware.format_size(0, &buffer));
    try std.testing.expectEqualStrings("999  B", DumpHardware.format_size(999, &buffer));
    try std.testing.expectEqualStrings("1000 B", DumpHardware.format_size(1000, &buffer));
    try std.testing.expectEqualStrings("1    KB", DumpHardware.format_size(1500, &buffer));
    try std.testing.expectEqualStrings("976  KB", DumpHardware.format_size(1000000, &buffer));
    try std.testing.expectEqualStrings("2    MB", DumpHardware.format_size(2500000, &buffer));
    try std.testing.expectEqualStrings("953  MB", DumpHardware.format_size(1000000000, &buffer));
    try std.testing.expectEqualStrings("1    GB", DumpHardware.format_size(1250000000, &buffer));
    try std.testing.expectEqualStrings("TB", DumpHardware.format_size(1000000000000, &buffer));
}
