//
// hashtable.zig
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

const SymbolTable = @import("item_table.zig").SymbolTable;
const Symbol = @import("symbol.zig").Symbol;

fn yaff_hash_function(name: []const u8) u32 {
    var h: u32 = 0;
    var g: u32 = 0;
    for (name) |c| {
        h = (h << 4) + @as(u32, c);
        g = h & 0xf0000000;
        if (g != 0) {
            h ^= g >> 24;
        }
        h &= ~g;
    }
    return h;
}

pub const YaffHashTable = struct {
    nbucket: u32,
    nchain: u32,
    bucket: []u32,
    chain: []u32,

    pub fn lookup(hashtable: YaffHashTable, name: []const u8, table: *const SymbolTable) ?*const Symbol {
        const h: u32 = yaff_hash_function(name);
        var idx: u32 = hashtable.bucket[h % hashtable.nbucket];

        while (idx != 0) {
            const symbol = table.element_at(idx);
            if (symbol == null) {
                return null;
            }
            if (std.mem.eql(u8, symbol.?.name(), name)) {
                return symbol;
            }
            idx = hashtable.chain[idx];
        }
        return null;
    }
};
