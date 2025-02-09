//
// relocation_table.zig
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

const Section = @import("section.zig").Section;

pub const SymbolTableRelocation = packed struct {
    index: u32,
    symbol_index: u32,

    pub fn next(self: SymbolTableRelocation) *const SymbolTableRelocation {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(SymbolTableRelocation));
    }
};

pub const DataRelocation = packed struct {
    to: u32,
    section: u2,
    from: u30,

    pub fn next(self: DataRelocation) *const DataRelocation {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(DataRelocation));
    }
};

pub const LocalRelocation = packed struct {
    section: u2,
    index: u30,
    target_offset: u32,

    pub fn next(self: LocalRelocation) *const LocalRelocation {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(DataRelocation));
    }
};

pub fn RelocationTable(comptime RelocationType: anytype) type {
    return struct {
        relocations: []align(4) RelocationType,

        const Self = @This();

        pub fn size(self: Self) usize {
            return self.relocations.len * @sizeOf(RelocationType);
        }

        pub fn address(self: Self) usize {
            return @intFromPtr(self.relocations.ptr);
        }
    };
}

comptime {
    const std = @import("std");
    var buf: [30]u8 = undefined;
    if (@sizeOf(DataRelocation) != 8) @compileError("DataRelocation has incorrect size: " ++ (std.fmt.bufPrint(&buf, "{d}", .{@sizeOf(DataRelocation)}) catch "unknown"));
    if (@sizeOf(LocalRelocation) != 8) @compileError("LocalRelocation has incorrect size: " ++ (std.fmt.bufPrint(&buf, "{d}", .{@sizeOf(LocalRelocation)}) catch "unknown"));
    if (@sizeOf(SymbolTableRelocation) != 8) @compileError("SymbolRelocation has incorrect size: " ++ (std.fmt.bufPrint(&buf, "{d}", .{@sizeOf(SymbolTableRelocation)}) catch "unknown"));
}
