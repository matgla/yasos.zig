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
const log = std.log.scoped(.yasld);
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

pub fn print_header(header: *const Header) void {
    log.debug("  YAFF header: {{", .{});
    log.debug("    marker: '{s}' (0x{x}),", .{ std.mem.asBytes(&header.marker), header.marker });
    log.debug("    type: {s},", .{@tagName(@as(Type, @enumFromInt(header.module_type)))});
    log.debug("    arch: {s},", .{@tagName(@as(Architecture, @enumFromInt(header.arch)))});
    log.debug("    yaff_version: {d},", .{header.yasiff_version});
    log.debug("    code_length: 0x{x},", .{header.code_length});
    log.debug("    init_length: 0x{x},", .{header.init_length});
    log.debug("    data_length: 0x{x},", .{header.data_length});
    log.debug("    bss_length: 0x{x},", .{header.bss_length});
    log.debug("    entry: 0x{x},", .{header.entry});
    log.debug("    external_libraries: 0x{x},", .{header.external_libraries_amount});
    log.debug("    alignment: {d},", .{header.alignment});
    log.debug("    version: {d}.{d},", .{ header.version_major, header.version_minor });
    log.debug("    relocations:", .{});
    log.debug("      symbol_table: {d},", .{header.symbol_table_relocations_amount});
    log.debug("      local: {d},", .{header.local_relocations_amount});
    log.debug("      data: {d},", .{header.data_relocations_amount});
    log.debug("    exported_symbols: {d},", .{header.exported_symbols_amount});
    log.debug("    imported_symbols: {d},", .{header.imported_symbols_amount});
    log.debug("    got_size: {d},", .{header.got_length});
    log.debug("    got_plt_size: {d},", .{header.got_plt_length});
    log.debug("    plt_size: {d},", .{header.plt_length});
    log.debug("    arch_section_offset: {d},", .{header.arch_section_offset});
    log.debug("    imported_libraries_offset: {d},", .{header.imported_libraries_offset});
    log.debug("    relocations_offset: {d},", .{header.relocations_offset});
    log.debug("    imported_symbols_offset: {d},", .{header.imported_symbols_offset});
    log.debug("    exported_symbols_offset: {d},", .{header.exported_symbols_offset});
    log.debug("    text_offset: {d},", .{header.text_offset});

    log.debug("  }}", .{});
}

comptime {
    var buf: [30]u8 = undefined;
    if (@sizeOf(Header) != 72) @compileError("Header has incorrect size: " ++ (std.fmt.bufPrint(&buf, "{d}", .{@sizeOf(Header)}) catch "unknown"));
}
