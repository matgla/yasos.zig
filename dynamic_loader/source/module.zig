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

const SymbolTable = @import("item_table.zig").SymbolTable;
const Section = @import("section.zig").Section;
const Header = @import("header.zig").Header;
const Parser = @import("parser.zig").Parser;

const get_loader = @import("loader.zig").get_loader;

const log = std.log.scoped(.@"yasld/module");

pub const GotEntry = extern struct {
    symbol_offset: usize,
    base_register: usize,
};

pub const SymbolEntry = struct {
    target_got_address: usize,
    address: usize,
};

pub const LoadedSharedData = struct {
    text: ?[]const u8,
    init: ?[]const u8,
    plt: ?[]const u8,
    xip: bool,
    exported_symbols: SymbolTable,
    allocator: std.mem.Allocator,
    process_allocator: std.mem.Allocator,

    pub fn create(
        allocator: std.mem.Allocator,
        process_allocator: std.mem.Allocator,
        xip: bool,
        parser: *const Parser,
    ) !*LoadedSharedData {
        const self = try allocator.create(LoadedSharedData);
        if (xip) {
            self.* = .{
                .text = parser.get_text(),
                .init = parser.get_init(),
                .plt = parser.get_plt(),
                .xip = xip,
                .exported_symbols = parser.exported_symbols,
                .allocator = allocator,
                .process_allocator = process_allocator,
            };
        }
        return self;
    }

    pub fn destroy(self: *LoadedSharedData) void {
        self.allocator.destroy(self);
    }
};

pub const LoadedUniqueData = struct {
    data: ?[]u8,
    bss: ?[]u8,
    got: ?[]GotEntry,
    allocator: std.mem.Allocator,
    process_allocator: std.mem.Allocator,
    _underlaying_memory: []u8,

    pub fn create(allocator: std.mem.Allocator, process_allocator: std.mem.Allocator, header: *const Header, parser: *const Parser) !*LoadedUniqueData {
        const self = try allocator.create(LoadedUniqueData);
        // memory is combined just for optimization purposes, they may even fit in single page for small modules
        const underlaying_memory = try process_allocator.alloc(u8, header.data_length + header.bss_length + header.got_length);
        const got_pointer: [*]GotEntry = @ptrFromInt(@intFromPtr(underlaying_memory.ptr) + header.data_length + header.bss_length);
        self.* = .{
            .data = null,
            .bss = null,
            .got = null,
            .allocator = allocator,
            .process_allocator = process_allocator,
            ._underlaying_memory = underlaying_memory,
        };
        if (header.data_length > 0) {
            self.data = underlaying_memory[0..header.data_length];
            @memcpy(self.data.?, parser.get_data());
        }

        if (header.bss_length > 0) {
            self.bss = underlaying_memory[header.data_length .. header.bss_length + header.data_length];
            @memset(self.bss.?, 0);
        }

        if (header.got_length > 0) {
            self.got = got_pointer[0 .. header.got_length / @sizeOf(GotEntry)];
            @memcpy(self._underlaying_memory[header.data_length + header.bss_length ..], parser.get_got());
        }

        // copy data

        return self;
    }

    pub fn destroy(self: *LoadedUniqueData) void {
        self.process_allocator.free(self._underlaying_memory);
        self.allocator.destroy(self);
    }
};

pub const Module = struct {
    // this allocator is used for the module itself
    allocator: std.mem.Allocator,
    process_allocator: std.mem.Allocator,
    // xip determines if the read only memory is copied to ram
    xip: bool,
    shared_data: ?*LoadedSharedData,
    unique_data: ?*LoadedUniqueData,
    // this needs to be corelated with thread info
    entry: ?SymbolEntry = null,
    list_node: std.DoublyLinkedList.Node,
    child_list_node: std.DoublyLinkedList.Node,
    name: ?[]const u8,
    children: std.DoublyLinkedList,

    pub fn create(allocator: std.mem.Allocator, process_allocator: std.mem.Allocator, xip: bool) !*Module {
        const module = try allocator.create(Module);
        module.* = .{
            .allocator = allocator,
            .process_allocator = process_allocator,
            .xip = xip,
            .shared_data = null,
            .unique_data = null,
            .list_node = .{},
            .child_list_node = .{},
            .name = null,
            .children = .{},
        };
        return module;
    }

    pub fn add_shared_data(self: *Module, data: *LoadedSharedData) void {
        self.shared_data = data;
    }

    pub fn append_child(self: *Module, child: *Module) void {
        self.children.append(&child.child_list_node);
    }

    pub fn destroy(self: *Module) void {
        var next = self.children.pop();
        while (next) |node| {
            const child: *Module = @fieldParentPtr("child_list_node", node);
            child.destroy();
            next = self.children.pop();
        }

        if (get_loader()) |loader| {
            loader.*.unload_module(self);
        }

        if (self.unique_data) |data| {
            data.destroy();
        }

        if (self.name) |n| {
            log.debug("removal of '{s}'", .{n});
            self.allocator.free(n);
        }
        self.allocator.destroy(self);
    }

    pub fn set_name(self: *Module, name: []const u8) !void {
        if (self.name) |n| {
            self.allocator.free(n);
        }
        self.name = try self.allocator.dupe(u8, name);
        log.debug("created module: {s}", .{name});
    }

    pub fn get_base_address(self: Module, section: Section) error{UnknownSection}!usize {
        switch (section) {
            .Code => {
                if (self.shared_data) |shared_data| {
                    if (shared_data.text) |*text| {
                        return @intFromPtr(text.ptr);
                    }
                }
            },
            .Init => {
                if (self.shared_data) |shared_data| {
                    if (shared_data.init) |*init| {
                        return @intFromPtr(init.ptr);
                    }
                }
            },
            .Data => {
                if (self.unique_data) |unique_data| {
                    if (unique_data.data) |*data| {
                        return @intFromPtr(data.ptr);
                    }
                }
            },
            .Bss => {
                if (self.unique_data) |unique_data| {
                    if (unique_data.bss) |*bss| {
                        return @intFromPtr(bss.ptr);
                    }
                }
            },
            else => {
                return error.UnknownSection;
            },
        }
        return error.UnknownSection;
    }

    pub fn find_local_symbol(self: Module, name: []const u8) ?usize {
        if (self.shared_data) |shared_data| {
            var it = shared_data.exported_symbols.iter();
            while (it) |symbol| : (it = symbol.next()) {
                if (symbol.data.name().len == name.len and std.mem.eql(u8, symbol.data.name(), name)) {
                    const base = self.get_base_address(@enumFromInt(symbol.data.section)) catch return null;
                    return base + symbol.data.offset;
                }
            }
        }
        return null;
    }

    pub fn find_symbol(self: *const Module, name: []const u8) ?SymbolEntry {
        const maybe_local_symbol = self.find_local_symbol(name);
        if (self.unique_data) |*data| {
            if (data.*.got) |got| {
                if (maybe_local_symbol) |symbol| {
                    return .{
                        .address = symbol,
                        .target_got_address = @intFromPtr(got.ptr),
                    };
                }
            }
        }

        var it = self.children.first;
        while (it) |child_node| : (it = child_node.next) {
            const module: *const Module = @fieldParentPtr("child_list_node", child_node);
            const maybe_child_symbol = module.find_local_symbol(name);
            if (module.unique_data) |*data| {
                if (data.*.got) |*got| {
                    if (maybe_child_symbol) |symbol| {
                        return .{
                            .address = symbol,
                            .target_got_address = @intFromPtr(got.ptr),
                        };
                    }
                }
            }
        }

        return null;
    }

    const ModuleError = error{
        UnhandledInitAddress,
    };

    pub fn relocate_init(self: *Module, initializers: []const u8, header: *const Header) !void {
        _ = self;
        _ = header;
        if (initializers.len > 0) {
            @panic("relocate_init not implemented");
        }
        //     var init: []const u8 = undefined;

        //     if (self.shared_data) |shared_data| {
        //         if (shared_data.init) |*i| {
        //             init = i;
        //         }
        //     }

        //     @memcpy(init_data, initializers);
        //     const text_end: usize = header.code_length;
        //     const init_end: usize = text_end + header.init_length;
        //     const data_end: usize = init_end + header.data_length;
        //     const bss_end: usize = data_end + header.bss_length;

        //     for (0..init_data.len / 4) |i| {
        //         const entry: *u32 = @ptrCast(@alignCast(&init_data[i * 4]));
        //         if (entry.* < text_end) {
        //             entry.* = entry.* + @intFromPtr(self.get_text().ptr);
        //         } else if (entry.* < init_end) {
        //             entry.* = entry.* + @intFromPtr(self.get_init().ptr);
        //         } else if (entry.* < data_end) {
        //             entry.* = entry.* + @intFromPtr(self.get_data().ptr);
        //         } else if (entry.* < bss_end) {
        //             entry.* = entry.* + @intFromPtr(self.get_bss().ptr);
        //         } else {
        //             return ModuleError.UnhandledInitAddress;
        //         }
        //     }
    }

    // process initializers using C-symbols
    // used for example for current TCC implementation
    // that exports __section_start instead of .init_array
    pub fn process_initializers(self: *Module) void {
        _ = self;
    }

    pub fn get_got(self: *const Module) []GotEntry {
        if (self.unique_data) |*data| {
            if (data.*.got) |got| {
                return got;
            }
        }
        return &.{};
    }

    pub fn get_text(self: *const Module) []const u8 {
        if (self.shared_data) |shared_data| {
            if (shared_data.text) |text| {
                return text;
            }
        }
        return &.{};
    }

    pub fn get_data(self: *const Module) []u8 {
        if (self.unique_data) |unique_data| {
            if (unique_data.data) |data| {
                return data;
            }
        }
        return &.{};
    }

    pub fn get_init(self: *const Module) []const u8 {
        if (self.shared_data) |shared_data| {
            if (shared_data.init) |init| {
                return init;
            }
        }
        return &.{};
    }

    pub fn get_plt(self: *const Module) []const u8 {
        if (self.shared_data) |shared_data| {
            if (shared_data.plt) |plt| {
                return plt;
            }
        }
        return &.{};
    }

    pub fn get_bss(self: *const Module) []u8 {
        if (self.unique_data) |unique_data| {
            if (unique_data.bss) |bss| {
                return bss;
            }
        }
        return &.{};
    }

    // pub fn get_got_plt(self: *const Module) []usize {
    //     const got_plt_start = self.header.code_length + self.header.data_length + self.header.init_length + self.header.bss_length + self.header.got_length + self.header.plt_length;
    //     const got_plt_end = (self.header.got_plt_length / 4);

    //     return @as([*]usize, @ptrFromInt(@intFromPtr(self.program.?.ptr) + got_plt_start))[0..got_plt_end];
    // }

    // pub fn get_plt(self: *const Module) []usize {
    //     const plt_start = self.header.code_length + self.header.data_length + self.header.init_length + self.header.bss_length;
    //     const plt_end = (self.header.plt_length / 4);

    //     return @as([*]usize, @ptrFromInt(@intFromPtr(self.program.?.ptr) + plt_start))[0..plt_end];
    // }

    // pub fn find_module_with_got(self: *const Module, got_address: usize) ?*Module {
    //     if (got_address == @as(usize, @intFromPtr(self.get_got().ptr))) {
    //         return self;
    //     }

    //     for (self.imported_modules.items) |module| {
    //         const maybe_module = module.find_module_with_got(got_address);
    //         if (maybe_module) |m| {
    //             return m;
    //         }
    //     }
    //     return null;
    // }
};
