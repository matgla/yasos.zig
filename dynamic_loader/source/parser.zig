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
const CopyRelocations = relocation.RelocationTable(relocation.CopyRelocation);

/// A file-backed image; all parser pointers must stay within these bytes.
pub const Image = []align(4) const u8;
pub const ValidationError = error{InvalidImageLayout};

fn span_end(start: usize, count: usize, stride: usize, limit: usize) ValidationError!usize {
    if (start > limit or (stride != 0 and count > (limit - start) / stride)) return error.InvalidImageLayout;
    return start + count * stride;
}

fn names_end(image: Image, start: usize, end: usize, count: usize, prefix: usize, alignment: usize, lookup: ?[]align(1) const u16) ValidationError!usize {
    var at = start;
    if (end > image.len or start > end or count > (end - start) / (prefix + 1)) return error.InvalidImageLayout;
    for (0..count) |i| {
        if (lookup) |offsets| {
            if (offsets[i] != at - start) return error.InvalidImageLayout;
        }
        const name_at = try span_end(at, 1, prefix, end);
        const len = std.mem.indexOfScalar(u8, image[name_at..end], 0) orelse return error.InvalidImageLayout;
        const next = try span_end(name_at, len + 1, 1, end);
        const padding = (0 -% next) & (alignment - 1);
        at = try span_end(next, padding, 1, end);
        if (at > end) return error.InvalidImageLayout;
    }
    return at;
}

fn validate_hash(image: Image, start: usize, end: usize, symbols: usize) ValidationError!void {
    if (start % 4 != 0) return error.InvalidImageLayout;
    _ = try span_end(start, 2, 4, end);
    const words: [*]align(1) const u32 = @ptrCast(image.ptr + start);
    const buckets = words[0];
    const chains = words[1];
    if (buckets == 0 or chains != symbols) return error.InvalidImageLayout;
    const chain_at = try span_end(start + 8, buckets, 4, end);
    _ = try span_end(chain_at, chains, 4, end);
    for (words[2..][0..buckets]) |index| {
        if (index != 0 and index >= symbols) return error.InvalidImageLayout;
    }
    const chain: [*]align(1) const u32 = @ptrCast(image.ptr + chain_at);
    for (chain[0..chains]) |index| {
        if (index != 0 and index >= symbols) return error.InvalidImageLayout;
    }
    for (words[2..][0..buckets]) |first| {
        var index = first;
        var remaining = symbols;
        while (index != 0 and remaining != 0) : (remaining -= 1) index = chain[index];
        if (index != 0) return error.InvalidImageLayout;
    }
}

pub const Parser = struct {
    name: []const u8,
    imported_libraries: DependencyTable,
    symbol_table_relocations: SymbolTableRelocations,
    local_relocations: LocalRelocations,
    data_relocations: DataRelocations,
    copy_relocations: CopyRelocations,
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

    /// Validate the writer's layout once per immutable image. Required before create.
    pub fn validate(image: Image) ValidationError!void {
        if (image.len < @sizeOf(Header)) return error.InvalidImageLayout;
        const h: *const Header = @ptrCast(image.ptr);
        const alignment: usize = h.alignment;
        if (!std.math.isPowerOfTwo(alignment) or alignment < 4 or
            h.data_alignment == 0 or h.text_offset > image.len or h.const_rodata_length > h.data_length or
            h.got_length % 8 != 0 or h.got_plt_length != 0 or h.arch_section_offset < @sizeOf(Header) + 1) return error.InvalidImageLayout;
        const offsets = [_]usize{ h.arch_section_offset, h.imported_libraries_offset, h.relocations_offset, h.imported_symbols_offset, h.exported_symbols_offset, h.imported_symbols_lookup_offset, h.exported_symbols_lookup_offset, h.imported_symbols_hash_table_offset, h.exported_symbols_hash_table_offset, h.text_offset };
        var previous: usize = @sizeOf(Header);
        for (offsets, 0..) |offset, i| {
            if (offset < previous or offset > h.text_offset or offset % @as(usize, if (i == 6) 2 else 4) != 0) return error.InvalidImageLayout;
            previous = offset;
        }
        const name_len = std.mem.indexOfScalar(u8, image[@sizeOf(Header)..h.arch_section_offset], 0) orelse return error.InvalidImageLayout;
        _ = name_len;
        const Arch = @import("header.zig").ArchSection;
        _ = try span_end(h.arch_section_offset, 1, @sizeOf(Arch), h.imported_libraries_offset);
        const arch: *const Arch = @ptrCast(@alignCast(image.ptr + h.arch_section_offset));
        if (arch.size < @sizeOf(Arch)) return error.InvalidImageLayout;
        _ = try span_end(h.arch_section_offset, arch.size, 1, h.imported_libraries_offset);
        if (try names_end(image, h.imported_libraries_offset, h.relocations_offset, h.external_libraries_amount, 0, alignment, null) != h.relocations_offset) return error.InvalidImageLayout;
        var rel_end: usize = h.relocations_offset;
        rel_end = try span_end(rel_end, h.symbol_table_relocations_amount, @sizeOf(relocation.SymbolTableRelocation), h.imported_symbols_offset);
        rel_end = try span_end(rel_end, h.local_relocations_amount, @sizeOf(relocation.LocalRelocation), h.imported_symbols_offset);
        rel_end = try span_end(rel_end, h.data_relocations_amount, @sizeOf(relocation.DataRelocation), h.imported_symbols_offset);
        rel_end = try span_end(rel_end, h.copy_relocations_amount, @sizeOf(relocation.CopyRelocation), h.imported_symbols_offset);
        if (rel_end != h.imported_symbols_offset) return error.InvalidImageLayout;
        _ = try span_end(h.imported_symbols_lookup_offset, h.imported_symbols_amount, 2, h.exported_symbols_lookup_offset);
        _ = try span_end(h.exported_symbols_lookup_offset, h.exported_symbols_amount, 2, h.imported_symbols_hash_table_offset);
        const imported_lookup: [*]align(1) const u16 = @ptrCast(image.ptr + h.imported_symbols_lookup_offset);
        const exported_lookup: [*]align(1) const u16 = @ptrCast(image.ptr + h.exported_symbols_lookup_offset);
        if (try names_end(image, h.imported_symbols_offset, h.exported_symbols_offset, h.imported_symbols_amount, @sizeOf(Symbol), alignment, imported_lookup[0..h.imported_symbols_amount]) != h.exported_symbols_offset) return error.InvalidImageLayout;
        if (try names_end(image, h.exported_symbols_offset, h.imported_symbols_lookup_offset, h.exported_symbols_amount, @sizeOf(Symbol), alignment, exported_lookup[0..h.exported_symbols_amount]) != h.imported_symbols_lookup_offset) return error.InvalidImageLayout;
        try validate_hash(image, h.imported_symbols_hash_table_offset, h.exported_symbols_hash_table_offset, h.imported_symbols_amount);
        try validate_hash(image, h.exported_symbols_hash_table_offset, h.text_offset, h.exported_symbols_amount);
        var payload_end: usize = h.text_offset;
        for ([_]usize{ h.code_length, h.init_length, h.plt_length, h.data_length, h.got_length, h.got_plt_length }) |length| {
            payload_end = try span_end(payload_end, length, 1, image.len);
        }
        const data_bss = std.math.add(usize, h.data_length, h.bss_length) catch return error.InvalidImageLayout;
        const region_length = std.math.add(usize, data_bss, h.got_length) catch return error.InvalidImageLayout;
        _ = std.math.add(usize, region_length, h.data_alignment - 1) catch return error.InvalidImageLayout;
        // Bounded chains are checked during lookup too, so malformed cycles cannot hang.
        const parser = create(h);
        for (parser.symbol_table_relocations.relocations) |rel| {
            const count = if (rel.is_exported_symbol != 0) h.exported_symbols_amount else h.imported_symbols_amount;
            if (rel.index >= h.got_length / 8 or rel.symbol_index >= count) return error.InvalidImageLayout;
        }
        for (parser.local_relocations.relocations) |rel| {
            if (rel.index >= h.got_length / 8 or rel.section == 3) return error.InvalidImageLayout;
        }
        for (parser.data_relocations.relocations) |rel| {
            if (rel.to < h.const_rodata_length or rel.to % 4 != 0) return error.InvalidImageLayout;
            _ = try span_end(rel.to, 1, 4, data_bss);
            if (rel.section == 3 and rel.from >= h.got_length / 8) return error.InvalidImageLayout;
        }
        for (parser.copy_relocations.relocations) |rel| {
            _ = try span_end(rel.bss_offset, rel.size, 1, h.bss_length);
            if (rel.symbol_index >= h.imported_symbols_amount) return error.InvalidImageLayout;
        }
    }

    pub fn create(header: *const Header) Parser {
        const name: []const u8 = std.mem.span(@as([*:0]const u8, @ptrFromInt(@intFromPtr(header) + @sizeOf(Header))));
        // The table no longer follows the name directly -- the architecture
        // section sits between them -- so take the offset the writer recorded
        // rather than recomputing the layout here.
        const imported_libraries = DependencyTable{
            .number_of_items = header.external_libraries_amount,
            .alignment = header.alignment,
            .root = @as(*const Dependency, @ptrFromInt(@intFromPtr(header) + header.imported_libraries_offset)),
            .lookup = &[_]u16{},
        };

        const symbol_table_start = @intFromPtr(header) + header.relocations_offset;

        const symbol_table_array: [*]align(4) relocation.SymbolTableRelocation = @ptrFromInt(symbol_table_start);

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

        const copy_relocation_array: [*]align(4) relocation.CopyRelocation = @ptrFromInt(data_relocations.address() + data_relocations.size());
        const copy_relocations = CopyRelocations{
            .relocations = copy_relocation_array[0..header.copy_relocations_amount],
        };

        // Parsed before the symbol tables are built, because they are handed to
        // those tables. Every image carries these -- the writer has always
        // emitted them -- but until 2026-08-03 nothing attached them, so
        // `element_by_name` took its linear-scan fallback on every lookup and a
        // process spawn cost ~48 ms of strlen-strided walking through XIP flash.
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

        const imported_symbols_start = @intFromPtr(header) + header.imported_symbols_offset;

        const imported_array = SymbolTable{
            .number_of_items = header.imported_symbols_amount,
            .alignment = header.alignment,
            .root = @as(*const Symbol, @ptrFromInt(imported_symbols_start)),
            .lookup = @as([*]u16, @ptrFromInt(@intFromPtr(header) + header.imported_symbols_lookup_offset))[0..header.imported_symbols_amount],
            .hashtable = if (header.imported_symbols_amount > 0) imported_symbols_hash_table else null,
        };

        const exported_start = @intFromPtr(header) + header.exported_symbols_offset;

        const exported_array = SymbolTable{
            .number_of_items = header.exported_symbols_amount,
            .alignment = header.alignment,
            .root = @as(*const Symbol, @ptrFromInt(exported_start)),
            .lookup = @as([*]u16, @ptrFromInt(@intFromPtr(header) + header.exported_symbols_lookup_offset))[0..header.exported_symbols_amount],
            .hashtable = if (header.exported_symbols_amount > 0) exported_symbols_hash_table else null,
        };

        const text: usize = @intFromPtr(header) + header.text_offset;
        const init: usize = text + header.code_length;
        const plt: usize = init + header.init_length;
        const data: usize = plt + header.plt_length;
        const got: usize = data + header.data_length;
        const got_plt: usize = got + header.got_length;

        return Parser{
            .name = name,
            .imported_libraries = imported_libraries,
            .symbol_table_relocations = symbol_table_relocations,
            .local_relocations = local_relocations,
            .data_relocations = data_relocations,
            .copy_relocations = copy_relocations,
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
            log.debug("  index: 0x{x}, target_offset: 0x{x}, section: {s}", .{ rel.index, rel.target_offset, @tagName(@as(Section, @fromBackingInt(@intCast(rel.section)))) });
        }
        log.debug("data relocations: {d}", .{self.data_relocations.relocations.len});
        for (self.data_relocations.relocations) |rel| {
            log.debug("  from: 0x{x}, to: 0x{x}, section: {s}", .{ rel.from, rel.to, @tagName(@as(Section, @fromBackingInt(@intCast(rel.section)))) });
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

    // RELRO: the first const_rodata_length bytes of the data region are
    // pure-const .rodata shared XIP across processes (borrowed, never copied).
    pub fn get_rodata(self: Parser) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.data_address);
        return ptr[0..self.header.const_rodata_length];
    }

    // The per-process data (everything after the shared rodata prefix).
    pub fn get_process_data(self: Parser) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.data_address + self.header.const_rodata_length);
        return ptr[0 .. self.header.data_length - self.header.const_rodata_length];
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

const testing = std.testing;

// The two ways `create` finds a table have to agree: the offsets the writer
// records, and the addresses implied by chaining the sizes. This is the small
// readable case behind the whole-rootfs precache byte-compare the gate runs.
// The image is laid out exactly as `tcc_yaff_write_*` lays a real one out --
// name, architecture section, dependency table, the relocation block, both
// symbol tables (each starting with the empty-name entry the writer emits),
// the lookup arrays and the hash tables.
test "Parser.ReadsTablesFromTheHeaderOffsets" {
    // The header is the first thing in a YAFF image and every table offset is
    // measured from it, so the test keeps one contiguous buffer: `header` at
    // offset 0, the image bytes from @sizeOf(Header) on.
    const TestImage = extern struct {
        header: Header,
        bytes: [256]u8,
    };
    const at: u32 = @sizeOf(Header);

    var image: TestImage align(4) = std.mem.zeroes(TestImage);
    image.header.data_alignment = 4;
    @memset(&image.bytes, 0);

    image.header.alignment = 4;
    image.header.arch_section_offset = at + 4;
    image.header.got_length = 8;
    image.bytes[4] = @sizeOf(@import("header.zig").ArchSection);
    image.header.external_libraries_amount = 1;
    image.header.symbol_table_relocations_amount = 1;
    image.header.local_relocations_amount = 0;
    image.header.data_relocations_amount = 0;
    image.header.copy_relocations_amount = 0;
    image.header.imported_symbols_amount = 2;
    image.header.exported_symbols_amount = 2;
    image.header.imported_libraries_offset = at + 16;
    image.header.relocations_offset = at + 24;
    image.header.imported_symbols_offset = at + 32;
    image.header.exported_symbols_offset = at + 48;
    image.header.imported_symbols_lookup_offset = at + 64;
    image.header.exported_symbols_lookup_offset = at + 68;
    image.header.imported_symbols_hash_table_offset = at + 72;
    image.header.exported_symbols_hash_table_offset = at + 100;
    image.header.text_offset = at + 128;

    @memcpy(image.bytes[0..4], "lib\x00");
    // at+4..at+16 is the architecture section, which `create` does not read.
    @memcpy(image.bytes[16..24], "libc\x00\x00\x00\x00");
    // One symbol-table relocation at at+24; no local, data or copy relocations.
    image.bytes[24] = 1;

    // Both symbol tables start with the empty-name entry, then one symbol whose
    // offset field carries 7 -- enough to tell the two entries apart.
    const sym: Symbol = .{ .section = 0, .weak = 0, .offset = 7 };
    @memcpy(image.bytes[40..44], std.mem.asBytes(&sym));
    @memcpy(image.bytes[44..48], "abc\x00");
    @memcpy(image.bytes[56..60], std.mem.asBytes(&sym));
    @memcpy(image.bytes[60..64], "xyz\x00");

    // The lookup arrays are byte offsets into the table, entry 0 first.
    const imported_lookup: [2]u16 align(4) = .{ 0, 8 };
    @memcpy(image.bytes[64..68], std.mem.asBytes(&imported_lookup));
    const exported_lookup: [2]u16 align(4) = .{ 0, 8 };
    @memcpy(image.bytes[68..72], std.mem.asBytes(&exported_lookup));

    // The hash table the writer would build for these two names: the empty
    // name is unreachable (its bucket value is the 0 terminator), "abc" and
    // "xyz" both land on bucket 0 -> table index 1.
    const imported_hash: [7]u32 align(4) = .{ 3, 2, 1, 0, 0, 0, 0 };
    @memcpy(image.bytes[72..100], std.mem.asBytes(&imported_hash));
    const exported_hash: [7]u32 align(4) = .{ 3, 2, 1, 0, 0, 0, 0 };
    @memcpy(image.bytes[100..128], std.mem.asBytes(&exported_hash));

    const by_offset = Parser.create(&image.header);
    const base = @intFromPtr(&image.header);

    try Parser.validate(std.mem.asBytes(&image));
    try testing.expectEqual(@as(usize, at + 32), by_offset.imported_symbols.address() - base);
    try testing.expectEqual(@as(usize, at + 48), by_offset.exported_symbols.address() - base);
    try testing.expectEqualStrings("abc", by_offset.imported_symbols.element_by_name("abc").?.name());
    try testing.expectEqualStrings("xyz", by_offset.exported_symbols.element_at(1).?.name());

    // Missing/corrupt fields are errors, never an unbounded fallback.
    for ([_]u32{ 0, 4, at + 25, 0xffffffff }) |offset| {
        var bad: TestImage align(4) = image;
        bad.header.relocations_offset = offset;
        try testing.expectError(error.InvalidImageLayout, Parser.validate(std.mem.asBytes(&bad)));
    }
    var bad: TestImage align(4) = image;
    bad.header.symbol_table_relocations_amount = 0xffffffff;
    try testing.expectError(error.InvalidImageLayout, Parser.validate(std.mem.asBytes(&bad)));
    bad = image;
    @memset(bad.bytes[44..48], 'x');
    try testing.expectError(error.InvalidImageLayout, Parser.validate(std.mem.asBytes(&bad)));
    bad = image;
    bad.header.data_alignment = 0;
    try testing.expectError(error.InvalidImageLayout, Parser.validate(std.mem.asBytes(&bad)));
    bad = image;
    bad.bytes[96] = 1; // hash chain[1] points back to itself
    try testing.expectError(error.InvalidImageLayout, Parser.validate(std.mem.asBytes(&bad)));
    bad = image;
    bad.bytes[28] = 0xff; // symbol index outside its table
    try testing.expectError(error.InvalidImageLayout, Parser.validate(std.mem.asBytes(&bad)));
    bad = image;
    bad.header.code_length = 0xffffffff;
    try testing.expectError(error.InvalidImageLayout, Parser.validate(std.mem.asBytes(&bad)));
    try testing.expectError(error.InvalidImageLayout, Parser.validate(std.mem.asBytes(&image)[0 .. at + 127]));
}
