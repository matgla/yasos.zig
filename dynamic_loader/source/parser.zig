//
// parser.zig
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
const DependencyTable = @import("item_table.zig").DependencyTable;
const SymbolTable = @import("item_table.zig").SymbolTable;

const Symbol = @import("symbol.zig").Symbol;
const Dependency = @import("dependency.zig").Dependency;
const relocation = @import("relocation_table.zig");
const Header = @import("header.zig").Header;
const Section = @import("section.zig").Section;
const YaffHashTable = @import("hashtable.zig").YaffHashTable;

const SymbolTableRelocations = relocation.RelocationTable(relocation.SymbolTableRelocation);
const LocalRelocations = relocation.RelocationTable(relocation.LocalRelocation);
const DataRelocations = relocation.RelocationTable(relocation.DataRelocation);

pub const Parser = struct {
    name: []const u8,
    imported_libraries: DependencyTable,
    symbol_table_relocations: SymbolTableRelocations,
    local_relocations: LocalRelocations,
    data_relocations: DataRelocations,
    imported_symbols: SymbolTable,
    exported_symbols: SymbolTable,
    text_address: usize,
    init_address: usize,
    data_address: usize,
    got_address: usize,
    got_plt_address: usize,
    plt_address: usize,
    header: *const Header,
    imported_symbols_hash_table: YaffHashTable,
    exported_symbols_hash_table: YaffHashTable,

    pub fn create(header: *const Header) Parser {
        const name: []const u8 = std.mem.span(@as([*:0]const u8, @ptrFromInt(@intFromPtr(header) + @sizeOf(Header))));
        const imported_libraries = DependencyTable{
            .number_of_items = header.external_libraries_amount,
            .alignment = header.alignment,
            .root = @as(*const Dependency, @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(name.ptr) + name.len + 1, header.alignment))),
            .lookup = &[_]u16{},
        };

        const symbol_table_array: [*]align(4) relocation.SymbolTableRelocation = @ptrFromInt(imported_libraries.address() + imported_libraries.size());

        const symbol_table_relocations = SymbolTableRelocations{
            .relocations = symbol_table_array[0..header.symbol_table_relocations_amount],
        };

        const local_relocation_array: [*]align(4) relocation.LocalRelocation = @ptrFromInt(symbol_table_relocations.address() + symbol_table_relocations.size());
        const local_relocations = LocalRelocations{
            .relocations = local_relocation_array[0..header.local_relocations_amount],
        };

        const data_relocation_array: [*]align(4) relocation.DataRelocation = @ptrFromInt(local_relocations.address() + local_relocations.size());
        const data_relocations = DataRelocations{
            .relocations = data_relocation_array[0..header.data_relocations_amount],
        };

        const imported_array = SymbolTable{
            .number_of_items = header.imported_symbols_amount,
            .alignment = header.alignment,
            .root = @as(*const Symbol, @ptrFromInt(data_relocations.address() + data_relocations.size())),
            .lookup = @as([*]u16, @ptrFromInt(@intFromPtr(header) + header.imported_symbols_lookup_offset))[0..header.imported_symbols_amount],
        };

        const imported_array_size = imported_array.size();
        const exported_array = SymbolTable{
            .number_of_items = header.exported_symbols_amount,
            .alignment = header.alignment,
            .root = @as(*const Symbol, @ptrFromInt(imported_array.address() + imported_array_size)),
            .lookup = @as([*]u16, @ptrFromInt(@intFromPtr(header) + header.exported_symbols_lookup_offset))[0..header.exported_symbols_amount],
        };

        const text: usize = @intFromPtr(header) + header.text_offset;
        const init: usize = text + header.code_length;
        const plt: usize = init + header.init_length;
        const data: usize = plt + header.plt_length;
        const got: usize = data + header.data_length;
        const got_plt: usize = got + header.got_length;
        var imported_symbols_hash_table: YaffHashTable = .{
            .nbucket = 0,
            .nchain = 0,
            .bucket = &[_]u32{},
            .chain = &[_]u32{},
        };

        if (header.imported_symbols_amount > 0) {
            const imported_hash_table_data: [*]u32 = @as([*]u32, @ptrFromInt(@intFromPtr(header) + header.imported_symbols_hash_table_offset));
            imported_symbols_hash_table.nbucket = imported_hash_table_data[0];
            imported_symbols_hash_table.nchain = imported_hash_table_data[1];
            imported_symbols_hash_table.bucket = imported_hash_table_data[2..][0..imported_hash_table_data[0]];
            imported_symbols_hash_table.chain = imported_hash_table_data[2 + imported_hash_table_data[0] ..][0..imported_hash_table_data[1]];
        }

        var exported_symbols_hash_table: YaffHashTable = .{
            .nbucket = 0,
            .nchain = 0,
            .bucket = &[_]u32{},
            .chain = &[_]u32{},
        };
        if (header.exported_symbols_amount > 0) {
            const exported_hash_table_data: [*]u32 = @as([*]u32, @ptrFromInt(@intFromPtr(header) + header.exported_symbols_hash_table_offset));
            exported_symbols_hash_table.nbucket = exported_hash_table_data[0];
            exported_symbols_hash_table.nchain = exported_hash_table_data[1];
            exported_symbols_hash_table.bucket = exported_hash_table_data[2..][0..exported_hash_table_data[0]];
            exported_symbols_hash_table.chain = exported_hash_table_data[2 + exported_hash_table_data[0] ..][0..exported_hash_table_data[1]];
        }

        return Parser{
            .name = name,
            .imported_libraries = imported_libraries,
            .symbol_table_relocations = symbol_table_relocations,
            .local_relocations = local_relocations,
            .data_relocations = data_relocations,
            .imported_symbols = imported_array,
            .exported_symbols = exported_array,
            .text_address = text,
            .init_address = init,
            .data_address = data,
            .got_address = got,
            .got_plt_address = got_plt,
            .plt_address = plt,
            .header = header,
            .imported_symbols_hash_table = imported_symbols_hash_table,
            .exported_symbols_hash_table = exported_symbols_hash_table,
        };
    }

    pub fn print(self: Parser) void {
        log.debug("              name: {s}", .{self.name});
        log.debug("imported libraries: {d}, size: {x}", .{ self.imported_libraries.number_of_items, self.imported_libraries.address() });
        {
            var it = self.imported_libraries.iter();
            while (it) |library| : (it = library.next()) {
                log.debug("  {s}", .{library.data.name()});
            }
        }
        log.debug("symbol table relocations: {d}", .{self.symbol_table_relocations.relocations.len});
        for (self.symbol_table_relocations.relocations) |rel| {
            log.debug("  address: 0x{x}", .{@intFromPtr(&rel)});
            log.debug("  index: 0x{x}, symbol index: 0x{x}, fn_ptr: {d}, exported: {d}", .{ rel.index, rel.symbol_index, rel.function_pointer, rel.is_exported_symbol });
        }
        log.debug("local relocations: {d}", .{self.local_relocations.relocations.len});
        for (self.local_relocations.relocations) |rel| {
            log.debug("  index: 0x{x}, target_offset: 0x{x}, section: {s}", .{ rel.index, rel.target_offset, @tagName(@as(Section, @enumFromInt(rel.section))) });
        }
        log.debug("data relocations: {d}", .{self.data_relocations.relocations.len});
        for (self.data_relocations.relocations) |rel| {
            log.debug("  from: 0x{x}, to: 0x{x}, section: {s}", .{ rel.from, rel.to, @tagName(@as(Section, @enumFromInt(rel.section))) });
        }
        {
            log.debug("imported symbols: {d}", .{self.imported_symbols.number_of_items});
            var it = self.imported_symbols.iter();
            while (it) |symbol| : (it = symbol.next()) {
                const name = symbol.data.name();
                log.debug("  {s}: offset: {d}", .{ name, symbol.data.offset });
            }
        }
        {
            log.debug("exported symbols: {d}", .{self.exported_symbols.number_of_items});
            var it = self.exported_symbols.iter();
            while (it) |symbol| : (it = symbol.next()) {
                log.debug("  {s}: offset: {d}", .{ symbol.data.name(), symbol.data.offset });
            }
        }
        log.debug(".text: 0x{x}", .{self.text_address});
        log.debug(".init: 0x{x}", .{self.init_address});
        log.debug(".data: 0x{x}", .{self.data_address});
        log.debug(".plt: 0x{x}", .{self.plt_address});
        log.debug(".got: 0x{x}", .{self.got_address});
        log.debug(".got.plt: 0x{x}", .{self.got_plt_address});
    }

    pub fn get_data(self: Parser) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.data_address);
        return ptr[0..self.header.data_length];
    }

    pub fn get_text(self: Parser) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.text_address);
        return ptr[0..self.header.code_length];
    }

    pub fn get_got(self: Parser) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.got_address);
        return ptr[0..self.header.got_length];
    }

    pub fn get_got_plt(self: Parser) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.got_plt_address);
        return ptr[0..self.header.got_plt_length];
    }

    pub fn get_plt(self: Parser) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.plt_address);
        return ptr[0..self.header.plt_length];
    }

    pub fn get_init(self: Parser) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.init_address);
        return ptr[0..self.header.init_length];
    }
};
