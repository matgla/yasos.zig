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
// Temporary load-phase accounting; see load_profile.zig.
const profile = @import("load_profile.zig");

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

pub const ThunkHolderData = struct {
    data: []u8,
    refcount: usize,
    generated: bool,

    pub fn create(allocator: std.mem.Allocator, size: usize) !*ThunkHolderData {
        // One allocation: [ThunkHolderData header][thunk data]. The process
        // pool is page-granular, so a separate header struct would burn a whole
        // 4 KiB page for ~16 bytes. The header lives at the block head; the
        // thunk bytes (which the process executes) follow in the same RWX page.
        const hdr = @sizeOf(ThunkHolderData);
        const block = try allocator.alloc(u8, hdr + size * indirect_call_thunk_template_size);
        const self: *ThunkHolderData = @ptrCast(@alignCast(block.ptr));
        self.* = .{
            .data = block[hdr..],
            .refcount = 1,
            .generated = false,
        };
        return self;
    }

    pub fn delete(self: *ThunkHolderData, allocator: std.mem.Allocator) void {
        self.refcount -= 1;
        if (self.refcount == 0) {
            const hdr = @sizeOf(ThunkHolderData);
            const base: [*]u8 = @ptrCast(self);
            allocator.free(base[0 .. hdr + self.data.len]);
        }
    }
};

pub const LoadedSharedData = struct {
    text: ?[]const u8,
    init: ?[]const u8,
    plt: ?[]const u8,
    // RELRO: pure-const .rodata, borrowed XIP and shared across processes
    // (null when const_rodata_length == 0, i.e. -no-share-rodata).
    rodata: ?[]const u8,
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
            const rodata: ?[]const u8 = if (parser.header.const_rodata_length > 0) parser.get_rodata() else null;
            self.* = .{
                .text = parser.get_text(),
                .init = parser.get_init(),
                .plt = parser.get_plt(),
                .rodata = rodata,
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
    allocator: std.mem.Allocator,
    process_allocator: std.mem.Allocator,
    _underlaying_memory: []u8,

    pub fn create(allocator: std.mem.Allocator, process_allocator: std.mem.Allocator, header: *const Header, parser: *const Parser) !*LoadedUniqueData {
        const self = try allocator.create(LoadedUniqueData);
        // RELRO: the first const_rodata_length bytes of the data region are
        // pure-const .rodata, shared XIP (borrowed by LoadedSharedData) — they
        // are NOT allocated or copied per process. The per-process data segment
        // is just [data][bss][got]; DATA relocation offsets are mapped through
        // Module.resolve_data_offset (offset < const_rodata_length => the shared
        // rodata; otherwise => this buffer at offset - const_rodata_length).
        const data_part = header.data_length - header.const_rodata_length;
        // memory is combined just for optimization purposes, they may even fit in single page for small modules
        const _t_alloc = profile.now_us();
        const underlaying_memory = try process_allocator.alloc(u8, data_part + header.bss_length + header.got_length);
        profile.account(.process_data_alloc, _t_alloc);
        const _t_copy = profile.now_us();
        defer profile.account(.process_data_copy, _t_copy);
        const got_pointer: [*]GotEntry = @ptrFromInt(@intFromPtr(underlaying_memory.ptr) + data_part + header.bss_length);
        self.* = .{
            .data = null,
            .bss = null,
            .got = null,
            .thunks = null,
            .allocator = allocator,
            .process_allocator = process_allocator,
            ._underlaying_memory = underlaying_memory,
        };
        if (data_part > 0) {
            self.data = underlaying_memory[0..data_part];
            @memcpy(self.data.?, parser.get_process_data());
        }

        if (header.bss_length > 0) {
            self.bss = underlaying_memory[data_part .. header.bss_length + data_part];
            @memset(self.bss.?, 0);
        }

        if (header.got_length > 0) {
            self.got = got_pointer[0 .. header.got_length / @sizeOf(GotEntry)];
            @memcpy(self._underlaying_memory[data_part + header.bss_length ..], parser.get_got());
        }

        // copy data

        return self;
    }

    pub fn allocate_thunks(self: *LoadedUniqueData, size: usize) !void {
        if (self.thunks == null) {
            self.thunks = try ThunkHolderData.create(self.process_allocator, size);
        }
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
            // The head template embeds &indirect_call_shared_tail at +8 (copied
            // verbatim); patch only the per-slot {r9, fn} descriptor at +12/+16.
            @memcpy(thunks.data[position + 12 .. position + 12 + @sizeOf(usize)], std.mem.asBytes(&r9));
            @memcpy(thunks.data[position + 16 .. position + 16 + @sizeOf(usize)], std.mem.asBytes(&symbol));
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

    pub fn destroy(self: *LoadedUniqueData) void {
        // Free the regular thunks too — this was previously omitted (relying on
        // bulk process-pool teardown), which leaks on a library unload that does
        // not tear the pool down. refcount is always 1 (retain_thunks is gone),
        // so delete frees immediately.
        if (self.thunks) |thunks| {
            thunks.delete(self.process_allocator);
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
    // Per-image stack/heap profile (bytes) from the YAFF header.
    // 0xFFFFFFFF = use the OS default (kernel-driven stack; heap free to grow).
    stack_size: u32 = 0xFFFFFFFF,
    heap_size: u32 = 0xFFFFFFFF,
    // RELRO: bytes of pure-const .rodata shared XIP at the front of the data
    // region (0 = none). A DATA relocation offset below this lives in the
    // shared rodata; at or above it, in the per-process data buffer.
    const_rodata_length: u32 = 0,

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
            .stack_size = 0xFFFFFFFF,
            .heap_size = 0xFFFFFFFF,
            .const_rodata_length = 0,
        };
        return module;
    }

    // RELRO: map a DATA-section relocation offset (in the linker's
    // [rodata][data][bss][got] space) to a runtime address. Offsets below
    // const_rodata_length resolve to the shared XIP rodata; the rest to the
    // per-process [data][bss][got] buffer (which starts at const_rodata_length
    // in the offset space). With const_rodata_length == 0 this is the identity
    // data-base + offset (legacy behaviour).
    pub fn resolve_data_offset(self: Module, offset: usize) usize {
        if (self.const_rodata_length > 0 and offset < self.const_rodata_length) {
            if (self.shared_data) |shared| {
                if (shared.rodata) |rodata| {
                    return @intFromPtr(rodata.ptr) + offset;
                }
            }
        }
        if (self.unique_data) |unique| {
            return @intFromPtr(unique._underlaying_memory.ptr) + (offset - self.const_rodata_length);
        }
        return 0;
    }

    // Runtime address of (section, offset). DATA goes through the rodata-aware
    // resolver; every other section is its base + offset.
    pub fn address_in_section(self: Module, section: Section, offset: usize) error{UnknownSection}!usize {
        if (section == .Data) {
            return self.resolve_data_offset(offset);
        }
        return (try self.get_base_address(section)) + offset;
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
                // RELRO-aware: an exported pure-const symbol in .rodata (DATA
                // offset < const_rodata_length) resolves to the shared XIP rodata
                // so cross-module importers see the one shared copy.
                var address = self.address_in_section(section, symbol.offset) catch return null;
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
