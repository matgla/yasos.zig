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

const Dependency = @import("dependency.zig").Dependency;
const Symbol = @import("symbol.zig").Symbol;

pub fn ItemTable(comptime ItemType: anytype) type {
    return struct {
        root: *const ItemType,
        number_of_items: u16,
        alignment: u8,

        const Self = @This();

        pub fn create(table_address: usize, elements: u16, alignment: u8) Self {
            return .{
                .root = @ptrFromInt(table_address),
                .number_of_items = elements,
                .alignment = alignment,
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
            var it = self.iter();
            var i: usize = 0;
            while (it) |symbol| : ({
                it = symbol.next();
                i += 1;
            }) {
                if (i == index) {
                    return symbol.data;
                }
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
