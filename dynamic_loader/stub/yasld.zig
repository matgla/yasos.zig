//
// yasld.zig
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

pub const Executable = @import("executable.zig").Executable;
pub const Module = @import("module.zig").Module;
const loader = @import("loader.zig");
pub const get_loader = loader.get_loader;
pub const SymbolEntry = @import("module.zig").SymbolEntry;

pub fn loader_init(file_resolver: anytype, allocator: std.mem.Allocator) void {
    loader.init(file_resolver, allocator);
}
