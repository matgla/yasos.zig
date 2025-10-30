//
// module.zig
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

pub const SymbolEntry = struct {
    target_got_address: usize,
    address: usize,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    process_allocator: std.mem.Allocator,
    xip: bool,
    list_node: std.DoublyLinkedList.Node,
    entry: ?SymbolEntry,
    name: ?[]const u8,

    pub fn create(allocator: std.mem.Allocator, process_allocator: std.mem.Allocator, xip: bool) !*Module {
        const module = try allocator.create(Module);
        module.* = .{
            .allocator = allocator,
            .process_allocator = process_allocator,
            .xip = xip,
            .list_node = .{},
            .entry = null,
            .name = "dummy_module",
        };
        return module;
    }

    pub fn destroy(self: *Module) void {
        self.allocator.destroy(self);
    }

    pub fn find_symbol(self: *Module, name: []const u8) ?SymbolEntry {
        _ = self;
        _ = name;
        return .{
            .target_got_address = 0,
            .address = 0,
        };
    }
};
