//
// environment.zig
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

// Create some kind of static builder for OS to export necessary stuff
// Right now just stub to pass loader code

const std = @import("std");

pub const SymbolEntry = struct {
    name: []const u8,
    address: usize,
};

pub const Environment = struct {
    symbols: []const SymbolEntry,

    pub fn find_symbol(self: Environment, name: []const u8) ?SymbolEntry {
        for (self.symbols) |symbol| {
            if (std.mem.eql(u8, symbol.name, name)) {
                return symbol;
            }
        }
        return null;
    }
};
