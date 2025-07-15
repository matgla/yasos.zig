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
const memory = @import("hal").memory;

const kernel = @import("kernel");

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

    fn format_size(size: u64, buffer: []u8) []const u8 {
        if (size >= 1000000000000) {
            return std.fmt.bufPrint(buffer, "---", .{}) catch buffer[0..];
        } else if (size >= 1024 * 1024 * 1024) {
            return std.fmt.bufPrint(buffer, "{d: <4} GB", .{size / 1024 / 1024 / 1024}) catch buffer[0..];
        } else if (size >= 1024 * 1024) {
            return std.fmt.bufPrint(buffer, "{d: <4} MB", .{size / 1024 / 1024}) catch buffer[0..];
        } else if (size >= 1024) {
            return std.fmt.bufPrint(buffer, "{d: <4} KB", .{size / 1024}) catch buffer[0..];
        } else {
            return std.fmt.bufPrint(buffer, "{d: <4} B", .{size}) catch buffer[0..];
        }

        return buffer;
    }

    fn format_frequency(freq: u64, buffer: []u8) []const u8 {
        if (freq >= 1000000000000) {
            return std.fmt.bufPrint(buffer, "{d: <4} ---", .{freq / 1000000000000}) catch buffer[0..];
        } else if (freq >= 1000000000) {
            return std.fmt.bufPrint(buffer, "{d: <4} GHz", .{freq / 1000000000}) catch buffer[0..];
        } else if (freq >= 1000000) {
            return std.fmt.bufPrint(buffer, "{d: <4} MHz", .{freq / 1000000}) catch buffer[0..];
        } else if (freq >= 1000) {
            return std.fmt.bufPrint(buffer, "{d: <4} KHz", .{freq / 1000}) catch buffer[0..];
        } else {
            return std.fmt.bufPrint(buffer, "{d: <4} Hz", .{freq}) catch buffer[0..];
        }

        return buffer;
    }
};

test "format frequency" {
    try std.testing.expect(DumpHardware.format_frequency(0), "0 MHz");
}
