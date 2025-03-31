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

// move this to architecture implementation
pub const ForeignCallContext = extern struct {
    r9: usize = 0,
    lr: usize = 0,
    temp: [2]usize = .{ 0, 0 },
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    program_memory: ?[]u8 = null,
    program: ?[]u8 = null,
    exported_symbols: ?SymbolTable = null,
    name: ?[]const u8 = null,
    foreign_call_context: ForeignCallContext,
    imported_modules: std.ArrayList(Module),
    // this needs to be corelated with thread info
    active: bool,
    entry: ?usize = null,
    header: *const Header = undefined,

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{
            .allocator = allocator,
            .foreign_call_context = .{},
            .imported_modules = std.ArrayList(Module).init(allocator),
            .active = false,
        };
    }

    pub fn set_header(self: *Module, header: *const Header) void {
        self.header = header;
    }

    pub fn deinit(self: *Module) void {
        if (self.program_memory) |program| {
            self.allocator.free(program);
        }
        self.imported_modules.deinit();
    }

    pub fn allocate_program(self: *Module, program_size: usize) !void {
        self.program_memory = try self.allocator.alloc(u8, program_size + 16);
        const bytes_to_align = @as(usize, @intFromPtr(self.program_memory.?.ptr)) % 16;
        self.program = self.program_memory.?[bytes_to_align..];
    }

    // imported modules must use it's own memory thus cannot be shared
    pub fn allocate_modules(self: *Module, number_of_modules: usize) !void {
        _ = try self.imported_modules.addManyAsSlice(number_of_modules);
        for (self.imported_modules.items) |*module| {
            module.* = Module.init(self.allocator);
        }
    }

    pub fn get_base_address(self: Module, section: Section) error{UnknownSection}!usize {
        switch (section) {
            .Code => return @intFromPtr(self.program.?.ptr),
            .Data => return @intFromPtr(self.program.?.ptr) + self.header.code_length + self.header.init_length,
            .Init => return @intFromPtr(self.program.?.ptr) + self.header.code_length,
            .Bss => return @intFromPtr(self.program.?.ptr) + self.header.code_length + self.header.data_length + self.header.init_length,
            .Unknown => return error.UnknownSection,
        }
    }

    pub fn find_local_symbol(self: Module, name: []const u8) ?usize {
        var it = self.exported_symbols.?.iter();
        while (it) |symbol| : (it = symbol.next()) {
            if (std.mem.eql(u8, symbol.data.name(), name)) {
                const base = self.get_base_address(@enumFromInt(symbol.data.section)) catch return null;
                return base + symbol.data.offset;
            }
        }
        return null;
    }

    pub fn find_symbol(self: Module, name: []const u8) ?usize {
        const maybe_local_symbol = self.find_local_symbol(name);
        if (maybe_local_symbol) |symbol| {
            return symbol;
        }

        for (self.imported_modules.items) |module| {
            const maybe_symbol = module.find_symbol(name);
            if (maybe_symbol) |symbol| {
                return symbol;
            }
        }

        return null;
    }

    pub fn save_caller_state(self: *Module, context: ForeignCallContext) void {
        self.foreign_call_context = context;
    }

    const ModuleError = error{
        UnhandledInitAddress,
    };

    pub fn get_text(self: *Module) []u8 {
        return self.program.?[0..self.header.code_length];
    }

    pub fn get_init(self: *Module) []u8 {
        const init_start = self.header.code_length;
        const init_end = init_start + self.header.init_length;
        return self.program.?[init_start..init_end];
    }

    pub fn get_data(self: *Module) []u8 {
        const data_start = self.header.code_length + self.header.init_length;
        const data_end = data_start + self.header.data_length;
        return self.program.?[data_start..data_end];
    }

    pub fn get_bss(self: *Module) []u8 {
        const bss_start = self.header.code_length + self.header.init_length + self.header.data_length;
        const bss_end = bss_start + self.header.bss_length;
        return self.program.?[bss_start..bss_end];
    }

    pub fn relocate_init(self: *Module, initializers: []const u8) !void {
        var init_data = self.get_init();
        @memcpy(init_data, initializers);
        const text_end: usize = self.header.code_length;
        const init_end: usize = text_end + self.header.init_length;
        const data_end: usize = init_end + self.header.data_length;
        const bss_end: usize = data_end + self.header.bss_length;

        for (0..init_data.len / 4) |i| {
            const entry: *u32 = @ptrCast(@alignCast(&init_data[i * 4]));
            if (entry.* < text_end) {
                entry.* = entry.* + @intFromPtr(self.get_text().ptr);
            } else if (entry.* < init_end) {
                entry.* = entry.* + @intFromPtr(self.get_init().ptr);
            } else if (entry.* < data_end) {
                entry.* = entry.* + @intFromPtr(self.get_data().ptr);
            } else if (entry.* < bss_end) {
                entry.* = entry.* + @intFromPtr(self.get_bss().ptr);
            } else {
                return ModuleError.UnhandledInitAddress;
            }
        }
    }

    // process initializers using C-symbols
    // used for example for current TCC implementation
    // that exports __section_start instead of .init_array
    pub fn process_initializers(self: *Module, stdout: anytype) void {
        const maybe_preinit_array_start = self.find_local_symbol("__preinit_array_start");

        if (maybe_preinit_array_start) |preinit_array_start| {
            const maybe_preinit_array_end = self.find_local_symbol("__preinit_array_end");
            if (maybe_preinit_array_end) |preinit_array_end| {
                stdout.print("Both __preinit_array_start and __preinit_array_end found at {x} - {x}\n", .{ preinit_array_start, preinit_array_end });
            }
        }

        const maybe_init_array_start = self.find_local_symbol("__init_array_start");

        if (maybe_init_array_start) |init_array_start| {
            const maybe_init_array_end = self.find_local_symbol("__init_array_end");
            if (maybe_init_array_end) |init_array_end| {
                stdout.print("Both __init_array_start and __init_array_end found at {x} - {x}\n", .{ init_array_start, init_array_end });
            }
        }
    }

    pub fn is_module_for_program_counter(self: Module, pc: usize, only_active: bool) bool {
        {
            const text_start = self.get_base_address(Section.Code);
            const text_end = text_start + self.text.len;
            if (pc >= text_start and pc < text_end) {
                if (self.active or !only_active) {
                    return true;
                } else {
                    return false;
                }
            }
        }
        {
            const data_start = self.get_base_address(Section.Data);
            const data_end = data_start + self.data.?.len;
            if (pc >= data_start and pc < data_end) {
                if (self.active or !only_active) {
                    return true;
                } else {
                    return false;
                }
            }
        }
        {
            const bss_start = @intFromPtr(self.bss.?.ptr);
            const bss_end = bss_start + self.bss.?.len;
            if (pc >= bss_start and pc < bss_end) {
                if (self.active or !only_active) {
                    return true;
                } else {
                    return false;
                }
            }
        }
        return false;
    }

    pub fn find_module_for_program_counter(self: *const Module, pc: usize, only_active: bool) ?*Module {
        if (self.is_module_for_program_counter(pc, only_active)) {
            return self;
        }

        for (self.imported_modules.items) |module| {
            const maybe_module = module.find_module_for_program_counter(pc, only_active);
            if (maybe_module) |m| {
                return m;
            }
        }

        return null;
    }

    pub fn get_got(self: *const Module) []usize {
        const got_start = self.header.code_length + self.header.data_length + self.header.init_length + self.header.bss_length + self.header.plt_length;
        const got_end = (self.header.got_length / 4);

        return @as([*]usize, @ptrFromInt(@intFromPtr(self.program.?.ptr) + got_start))[0..got_end];
    }
    pub fn get_got_plt(self: *const Module) []usize {
        const got_plt_start = self.header.code_length + self.header.data_length + self.header.init_length + self.header.bss_length + self.header.got_length + self.header.plt_length;
        const got_plt_end = (self.header.got_plt_length / 4);

        return @as([*]usize, @ptrFromInt(@intFromPtr(self.program.?.ptr) + got_plt_start))[0..got_plt_end];
    }

    pub fn get_plt(self: *const Module) []usize {
        const plt_start = self.header.code_length + self.header.data_length + self.header.init_length + self.header.bss_length;
        const plt_end = (self.header.plt_length / 4);

        return @as([*]usize, @ptrFromInt(@intFromPtr(self.program.?.ptr) + plt_start))[0..plt_end];
    }

    pub fn find_module_with_got(self: *const Module, got_address: usize) ?*Module {
        if (got_address == @as(usize, @intFromPtr(self.get_got().ptr))) {
            return self;
        }

        for (self.imported_modules.items) |module| {
            const maybe_module = module.find_module_with_got(got_address);
            if (maybe_module) |m| {
                return m;
            }
        }
        return null;
    }
};
