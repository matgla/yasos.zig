//
// item_table.zig
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
const Dependency = @import("dependency.zig").Dependency;
const Symbol = @import("symbol.zig").Symbol;

const YaffHashTable = @import("hashtable.zig").YaffHashTable;

pub fn ItemTable(comptime ItemType: anytype) type {
    return struct {
        root: *const ItemType,
        lookup: []u16,
        number_of_items: u16,
        alignment: u8,
        hashtable: ?YaffHashTable = null,

        const Self = @This();

        pub fn create(table_address: usize, elements: u16, alignment: u8, lookup: []u16, hashtable: ?YaffHashTable) Self {
            return .{
                .root = @ptrFromInt(table_address),
                .number_of_items = elements,
                .alignment = alignment,
                .lookup = lookup,
                .hashtable = hashtable,
            };
        }

        pub fn address(self: Self) usize {
            return @intFromPtr(self.root);
        }

        pub fn size(self: Self) usize {
            var result: usize = 0;
            var it = self.root;
            for (0..self.number_of_items) |_| {
                result += it.size(self.alignment);
                it = it.next(self.alignment);
            }
            return result;
        }

        pub fn iter(self: Self) ?Iterator {
            if (self.number_of_items == 0) {
                return null;
            }
            return Iterator{
                .data = self.root,
                .end = @ptrFromInt(@intFromPtr(self.root) + self.size()),
                .alignment = self.alignment,
            };
        }

        pub fn element_at(self: Self, index: usize) ?*const ItemType {
            if (index >= self.lookup.len) {
                return null;
            }
            const offset = self.lookup[index];
            return @ptrFromInt(@intFromPtr(self.root) + offset);
        }

        pub fn element_by_name(self: *const Self, name: []const u8) ?*const ItemType {
            if (self.hashtable) |ht| {
                return ht.lookup(name, self);
            }
            // Fallback to linear search
            var it = self.root;
            for (0..self.number_of_items) |_| {
                if (std.mem.eql(u8, it.name(), name)) {
                    return it;
                }
                it = it.next(self.alignment);
            }
            return null;
        }

        pub const Iterator = struct {
            data: *const ItemType,
            end: *const ItemType,
            alignment: u8,
            pub fn next(self: Iterator) ?Iterator {
                if (@intFromPtr(self.data.next(self.alignment)) >= @intFromPtr(self.end)) {
                    return null;
                }
                return .{
                    .data = self.data.next(self.alignment),
                    .end = self.end,
                    .alignment = self.alignment,
                };
            }
        };
    };
}

pub const DependencyTable = ItemTable(Dependency);
pub const SymbolTable = ItemTable(Symbol);
