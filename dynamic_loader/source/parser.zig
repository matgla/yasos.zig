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

const DependencyTable = @import("item_table.zig").DependencyTable;
const SymbolTable = @import("item_table.zig").SymbolTable;

const Symbol = @import("symbol.zig").Symbol;
const Dependency = @import("dependency.zig").Dependency;
const relocation = @import("relocation_table.zig");
const Header = @import("header.zig").Header;
const Section = @import("section.zig").Section;

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

    pub fn create(header: *const Header, stdout: anytype) Parser {
        _ = stdout;
        const name: []const u8 = std.mem.span(@as([*:0]const u8, @ptrFromInt(@intFromPtr(header) + @sizeOf(Header))));
        const imported_libraries = DependencyTable{
            .number_of_items = header.external_libraries_amount,
            .alignment = header.alignment,
            .root = @as(*const Dependency, @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(name.ptr) + name.len + 1, header.alignment))),
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
        };

        const imported_array_size = imported_array.size();
        const exported_array = SymbolTable{
            .number_of_items = header.exported_symbols_amount,
            .alignment = header.alignment,
            .root = @as(*const Symbol, @ptrFromInt(imported_array.address() + imported_array_size)),
        };

        const text: usize = std.mem.alignForward(usize, exported_array.address() + exported_array.size(), 16);
        const init: usize = text + header.code_length;
        const data: usize = init + header.init_length;
        const plt: usize = data + header.data_length;
        const got: usize = plt + header.plt_length;
        const got_plt: usize = got + header.got_length;
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
        };
    }

    pub fn print(self: Parser, stdout: anytype) void {
        stdout.print("              name: {s}\n", .{self.name});
        stdout.print("imported libraries: {d}, size: {x}\n", .{ self.imported_libraries.number_of_items, self.imported_libraries.address() });
        {
            var it = self.imported_libraries.iter();
            while (it) |library| : (it = library.next()) {
                stdout.print("  {s}\n", .{library.data.name()});
            }
        }
        stdout.print("symbol table relocations: {d}\n", .{self.symbol_table_relocations.relocations.len});
        for (self.symbol_table_relocations.relocations) |rel| {
            stdout.print("  address: 0x{x}\n", .{@intFromPtr(&rel)});
            stdout.print("  index: 0x{x}, symbol index: 0x{x}\n", .{ rel.index, rel.symbol_index });
        }
        stdout.print("local relocations: {d}\n", .{self.local_relocations.relocations.len});
        for (self.local_relocations.relocations) |rel| {
            stdout.print("  index: 0x{x}, target_offset: 0x{x}, section: {s}\n", .{ rel.index, rel.target_offset, @tagName(@as(Section, @enumFromInt(rel.section))) });
        }
        stdout.print("data relocations: {d}\n", .{self.data_relocations.relocations.len});
        for (self.data_relocations.relocations) |rel| {
            stdout.print("  from: 0x{x}, to: 0x{x}, section: {s}\n", .{ rel.from, rel.to, @tagName(@as(Section, @enumFromInt(rel.section))) });
        }
        {
            stdout.print("imported symbols: {d}\n", .{self.imported_symbols.number_of_items});
            var it = self.imported_symbols.iter();
            while (it) |symbol| : (it = symbol.next()) {
                const name = symbol.data.name();
                stdout.print("  {s}: offset: {d}\n", .{ name, symbol.data.offset });
            }
        }
        {
            stdout.print("exported symbols: {d}\n", .{self.exported_symbols.number_of_items});
            var it = self.exported_symbols.iter();
            while (it) |symbol| : (it = symbol.next()) {
                stdout.print("  {s}: offset: {d}\n", .{ symbol.data.name(), symbol.data.offset });
            }
        }
        stdout.print(".text: 0x{x}\n", .{self.text_address});
        stdout.print(".init: 0x{x}\n", .{self.init_address});
        stdout.print(".data: 0x{x}\n", .{self.data_address});
        stdout.print(".plt: 0x{x}\n", .{self.plt_address});
        stdout.print(".got: 0x{x}\n", .{self.got_address});
        stdout.print(".got.plt: 0x{x}\n", .{self.got_plt_address});
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
