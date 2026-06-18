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

pub const LoadedUniqueData = struct {
    address: usize,
    size: usize,
    got: ?[]usize,
    // Mirrors the real loader's combined data/bss/got backing buffer so kernel
    // code (save_parent_writable_sections in source/kernel/modules.zig) compiles
    // against this host-test stub.
    _underlaying_memory: []u8 = &.{},
};

var empty_section = [_]u8{};

pub const Module = struct {
    allocator: std.mem.Allocator,
    process_allocator: std.mem.Allocator,
    xip: bool,
    list_node: std.DoublyLinkedList.Node,
    child_list_node: std.DoublyLinkedList.Node,
    children: std.DoublyLinkedList,
    entry: ?SymbolEntry,
    name: ?[]const u8,
    unique_data: ?LoadedUniqueData,
    // Mirrors the real Module's YAFF stack/heap profile so the exec path in
    // source/kernel/process_manager.zig compiles against this host-test stub.
    stack_size: u32 = 0xFFFFFFFF,
    heap_size: u32 = 0xFFFFFFFF,

    pub fn create(allocator: std.mem.Allocator, process_allocator: std.mem.Allocator, xip: bool) !*Module {
        const module = try allocator.create(Module);
        module.* = .{
            .allocator = allocator,
            .process_allocator = process_allocator,
            .xip = xip,
            .list_node = .{},
            .child_list_node = .{},
            .children = .{},
            .entry = null,
            .name = "dummy_module",
            .unique_data = null,
            .stack_size = 0xFFFFFFFF,
            .heap_size = 0xFFFFFFFF,
        };
        return module;
    }

    pub fn destroy(self: *Module) void {
        self.allocator.destroy(self);
    }

    // Section accessors mirroring the real Module API so kernel code that
    // renders /proc/<pid>/maps (source/kernel/modules.zig) compiles against
    // this host-test stub.
    pub fn get_text(self: *const Module) []const u8 {
        _ = self;
        return empty_section[0..];
    }

    pub fn get_plt(self: *const Module) []const u8 {
        _ = self;
        return empty_section[0..];
    }

    pub fn get_data(self: *const Module) []u8 {
        _ = self;
        return empty_section[0..];
    }

    pub fn get_bss(self: *const Module) []u8 {
        _ = self;
        return empty_section[0..];
    }

    pub fn get_got(self: *const Module) []const u8 {
        _ = self;
        return empty_section[0..];
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
