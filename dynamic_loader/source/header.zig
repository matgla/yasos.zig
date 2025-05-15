//
// header.zig
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

pub const Type = enum(u8) {
    Unknown = 0,
    Executable = 1,
    Library = 2,
};

pub const Architecture = enum(u16) {
    Unknown = 0,
    Armv6_m = 1,
};

pub const Header = packed struct {
    marker: u32,
    module_type: u8,
    arch: u16,
    yasiff_version: u8,
    code_length: u32,
    init_length: u32,
    data_length: u32,
    bss_length: u32,
    entry: u32,
    external_libraries_amount: u16,
    alignment: u8,
    text_and_data_separation: u8,
    version_major: u16,
    version_minor: u16,
    symbol_table_relocations_amount: u16,
    local_relocations_amount: u16,
    data_relocations_amount: u16,
    reserved2_: u16,
    exported_symbols_amount: u16,
    imported_symbols_amount: u16,
    got_length: u32,
    got_plt_length: u32,
    plt_length: u32,
    arch_section_offset: u16,
    imported_libraries_offset: u16,
    relocations_offset: u16,
    imported_symbols_offset: u16,
    exported_symbols_offset: u16,
    text_offset: u16,
};

pub fn print_header(header: *const Header, stdout: anytype) void {
    stdout.write("  YAFF header: {\n");
    stdout.print("    marker: '{s}' (0x{x}),\n", .{ std.mem.asBytes(&header.marker), header.marker });
    stdout.print("    type: {s},\n", .{@tagName(@as(Type, @enumFromInt(header.module_type)))});
    stdout.print("    arch: {s},\n", .{@tagName(@as(Architecture, @enumFromInt(header.arch)))});
    stdout.print("    yaff_version: {d},\n", .{header.yasiff_version});
    stdout.print("    code_length: 0x{x},\n", .{header.code_length});
    stdout.print("    init_length: 0x{x},\n", .{header.init_length});
    stdout.print("    data_length: 0x{x},\n", .{header.data_length});
    stdout.print("    bss_length: 0x{x},\n", .{header.bss_length});
    stdout.print("    entry: 0x{x},\n", .{header.entry});
    stdout.print("    external_libraries: 0x{x},\n", .{header.external_libraries_amount});
    stdout.print("    alignment: {d},\n", .{header.alignment});
    stdout.print("    version: {d}.{d},\n", .{ header.version_major, header.version_minor });
    stdout.write("    relocations:\n");
    stdout.print("      symbol_table: {d},\n", .{header.symbol_table_relocations_amount});
    stdout.print("      local: {d},\n", .{header.local_relocations_amount});
    stdout.print("      data: {d},\n", .{header.data_relocations_amount});
    stdout.print("    exported_symbols: {d},\n", .{header.exported_symbols_amount});
    stdout.print("    imported_symbols: {d},\n", .{header.imported_symbols_amount});
    stdout.print("    got_size: {d},\n", .{header.got_length});
    stdout.print("    got_plt_size: {d},\n", .{header.got_plt_length});
    stdout.print("    plt_size: {d},\n", .{header.plt_length});
    stdout.print("    arch_section_offset: {d},\n", .{header.arch_section_offset});
    stdout.print("    imported_libraries_offset: {d},\n", .{header.imported_libraries_offset});
    stdout.print("    relocations_offset: {d},\n", .{header.relocations_offset});
    stdout.print("    imported_symbols_offset: {d},\n", .{header.imported_symbols_offset});
    stdout.print("    exported_symbols_offset: {d},\n", .{header.exported_symbols_offset});
    stdout.print("    text_offset: {d},\n", .{header.text_offset});

    stdout.write("  }\n");
}

comptime {
    var buf: [30]u8 = undefined;
    if (@sizeOf(Header) != 72) @compileError("Header has incorrect size: " ++ (std.fmt.bufPrint(&buf, "{d}", .{@sizeOf(Header)}) catch "unknown"));
}
