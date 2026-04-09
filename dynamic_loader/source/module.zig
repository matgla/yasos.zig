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

extern const indirect_call_thunk_template_size: usize;
extern fn indirect_call_thunk_template_start() void;

extern const lazy_resolver_thunk_template_size: usize;
extern fn lazy_resolver_thunk_template_start() void;

/// Information passed to the lazy resolver at runtime.
/// One instance per lazily-bound GOT entry, embedded alongside the thunk.
pub const LazyBindingInfo = extern struct {
    module: *Module,
    got_entry: *GotEntry,
    symbol_name: usize, // [*:0]const u8 stored as usize for extern compat
    is_weak: u32,
};

pub const ThunkHolderData = struct {
    data: []u8,
    refcount: usize,
    generated: bool,

    pub fn create(allocator: std.mem.Allocator, size: usize) !*ThunkHolderData {
        const self = try allocator.create(ThunkHolderData);
        self.* = .{
            .data = try allocator.alloc(u8, size * indirect_call_thunk_template_size),
            .refcount = 1,
            .generated = false,
        };
        return self;
    }

    pub fn delete(self: *ThunkHolderData, allocator: std.mem.Allocator) void {
        self.refcount -= 1;
        if (self.refcount == 0) {
            allocator.free(self.data);
            allocator.destroy(self);
        }
    }
};

/// Holds lazy resolver thunks and their associated LazyBindingInfo structs.
pub const LazyThunkHolderData = struct {
    thunk_data: []u8,
    info_data: []LazyBindingInfo,
    count: usize,

    pub fn create(allocator: std.mem.Allocator, size: usize) !*LazyThunkHolderData {
        const self = try allocator.create(LazyThunkHolderData);
        self.* = .{
            .thunk_data = try allocator.alloc(u8, size * lazy_resolver_thunk_template_size),
            .info_data = try allocator.alloc(LazyBindingInfo, size),
            .count = 0,
        };
        return self;
    }

    pub fn destroy(self: *LazyThunkHolderData, allocator: std.mem.Allocator) void {
        allocator.free(self.thunk_data);
        allocator.free(self.info_data);
        allocator.destroy(self);
    }
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
    thunks: ?*ThunkHolderData,
    lazy_thunks: ?*LazyThunkHolderData,
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
            .thunks = null,
            .lazy_thunks = null,
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

    pub fn allocate_thunks(self: *LoadedUniqueData, size: usize) !void {
        if (self.thunks == null) {
            self.thunks = try ThunkHolderData.create(self.process_allocator, size);
        }
    }

    pub fn retain_thunks(self: *LoadedUniqueData) ?*ThunkHolderData {
        if (self.thunks) |thunks| {
            thunks.refcount += 1;
            return thunks;
        }
        return null;
    }

    pub fn generate_thunk(self: *LoadedUniqueData, index: usize, r9: usize, symbol: usize) !usize {
        if (self.thunks) |thunks| {
            const position = index * indirect_call_thunk_template_size;
            if (position + indirect_call_thunk_template_size > thunks.data.len) {
                return error.IndexOutOfBounds;
            }
            const thunk_template: [*]const u8 = @ptrFromInt(@intFromPtr(&indirect_call_thunk_template_start) - 1);
            const thunk_slice: []const u8 = thunk_template[0..indirect_call_thunk_template_size];
            @memcpy(thunks.data[position .. position + indirect_call_thunk_template_size], thunk_slice[0..]);
            @memcpy(thunks.data[position + 20 .. position + 20 + @sizeOf(usize)], std.mem.asBytes(&r9));
            @memcpy(thunks.data[position + 24 .. position + 24 + @sizeOf(usize)], std.mem.asBytes(&symbol));
            return @intFromPtr(&thunks.data[position]) | 1;
        }
        return error.ThunksNotAllocated;
    }

    pub fn get_thunk_address(self: *LoadedUniqueData, index: usize) !usize {
        if (self.thunks) |thunks| {
            const position = index * indirect_call_thunk_template_size;
            if (position + indirect_call_thunk_template_size > thunks.data.len) {
                return error.IndexOutOfBounds;
            }
            return @intFromPtr(&thunks.data[position]) | 1;
        }
        return error.ThunksNotAllocated;
    }

    pub fn allocate_lazy_thunks(self: *LoadedUniqueData, size: usize) !void {
        if (self.lazy_thunks == null) {
            self.lazy_thunks = try LazyThunkHolderData.create(self.process_allocator, size);
        }
    }

    pub fn generate_lazy_thunk(
        self: *LoadedUniqueData,
        module: *Module,
        got_entry: *GotEntry,
        symbol_name: [*:0]const u8,
        is_weak: bool,
    ) !usize {
        if (self.lazy_thunks) |lazy| {
            const index = lazy.count;
            const position = index * lazy_resolver_thunk_template_size;
            if (position + lazy_resolver_thunk_template_size > lazy.thunk_data.len) {
                return error.IndexOutOfBounds;
            }
            // Fill in the LazyBindingInfo for this entry
            lazy.info_data[index] = .{
                .module = module,
                .got_entry = got_entry,
                .symbol_name = @intFromPtr(symbol_name),
                .is_weak = if (is_weak) 1 else 0,
            };
            // Copy thunk template and patch literal pool
            const thunk_template: [*]const u8 = @ptrFromInt(@intFromPtr(&lazy_resolver_thunk_template_start) - 1);
            const thunk_slice: []const u8 = thunk_template[0..lazy_resolver_thunk_template_size];
            @memcpy(lazy.thunk_data[position .. position + lazy_resolver_thunk_template_size], thunk_slice[0..]);
            // Patch lazy_info_ptr at offset +24
            const info_ptr = @intFromPtr(&lazy.info_data[index]);
            @memcpy(lazy.thunk_data[position + 24 .. position + 24 + @sizeOf(usize)], std.mem.asBytes(&info_ptr));
            // Patch resolver_fn at offset +28
            const resolver_addr = @intFromPtr(&lazy_resolve);
            @memcpy(lazy.thunk_data[position + 28 .. position + 28 + @sizeOf(usize)], std.mem.asBytes(&resolver_addr));
            lazy.count += 1;
            return @intFromPtr(&lazy.thunk_data[position]) | 1;
        }
        return error.LazyThunksNotAllocated;
    }

    pub fn destroy(self: *LoadedUniqueData) void {
        if (self.lazy_thunks) |lazy| {
            lazy.destroy(self.process_allocator);
        }
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
            const maybe_symbol = shared_data.exported_symbols.element_by_name(name);
            if (maybe_symbol) |symbol| {
                const section: Section = @enumFromInt(symbol.section);
                const base = self.get_base_address(section) catch return null;
                var address = base + symbol.offset;
                // Cortex-M only supports Thumb mode. Code addresses used with
                // BX/BLX must have bit 0 set to stay in Thumb state; an even
                // address causes an INVSTATE HardFault.
                if ((section == .Code or section == .Init) and (address & 1 == 0)) {
                    address |= 1;
                }
                return address;
            }
            // var it = shared_data.exported_symbols.iter();
            // while (it) |symbol| : (it = symbol.next()) {
            //     if (symbol.data.name().len == name.len and std.mem.eql(u8, symbol.data.name(), name)) {
            //         const base = self.get_base_address(@enumFromInt(symbol.data.section)) catch return null;
            //         return base + symbol.data.offset;
            //     }
            // }
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

/// Lazy resolver function called from the lazy_resolver_thunk assembly stub.
/// Resolves the symbol, patches the GOT entry for future direct access,
/// and returns the resolved address in low 32 bits + target R9 in high 32 bits
/// as a u64 returned in r0:r1 per AAPCS (avoiding hidden-pointer ABI for structs > 4 bytes).
export fn lazy_resolve(info: *LazyBindingInfo) callconv(.c) u64 {
    const module: *Module = info.module;
    const symbol_name_ptr: [*:0]const u8 = @ptrFromInt(info.symbol_name);
    const name = std.mem.span(symbol_name_ptr);

    const maybe_entry = module.find_symbol(name);
    if (maybe_entry) |entry| {
        // Patch GOT entry for subsequent direct access
        info.got_entry.symbol_offset = entry.address;
        info.got_entry.base_register = entry.target_got_address;
        log.debug("lazy_resolve: resolved '{s}' -> 0x{x}, r9=0x{x}", .{ name, entry.address, entry.target_got_address });
        return @as(u64, entry.address) | (@as(u64, entry.target_got_address) << 32);
    } else if (info.is_weak != 0) {
        log.debug("lazy_resolve: weak symbol '{s}' not found, resolving to NULL", .{name});
        info.got_entry.symbol_offset = 0;
        info.got_entry.base_register = 0;
        return 0;
    } else {
        log.err("lazy_resolve: symbol '{s}' not found", .{name});
        @panic("lazy_resolve: unresolved symbol");
    }
}
