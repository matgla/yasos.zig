//
// loader.zig
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

const Executable = @import("executable.zig").Executable;
const Header = @import("header.zig").Header;
const print_header = @import("header.zig").print_header;
const Module = @import("module.zig").Module;
const Parser = @import("parser.zig").Parser;
const Type = @import("header.zig").Type;
const Section = @import("section.zig").Section;
const Symbol = @import("symbol.zig").Symbol;
const SymbolEntry = @import("module.zig").SymbolEntry;
const LoadedSharedData = @import("module.zig").LoadedSharedData;
const LoadedUniqueData = @import("module.zig").LoadedUniqueData;

const log = std.log.scoped(.yasld);

const LoaderError = error{
    DataProcessingFailure,
    SymbolTableRelocationFailure,
    FileResolverNotSet,
    DependencyNotFound,
    DependencyIsNotLibrary,
    SymbolNotFound,
    OutOfMemory,
    ChildLoadingFailure,
};

pub const Loader = struct {
    // OS should provide pointer to XIP region, it must be copied to RAM if needed
    pub const FileResolver = *const fn (name: []const u8) ?*const anyopaque;
    const LoadedModule = struct {
        shared_data: *LoadedSharedData,
        users: i32,
    };

    file_resolver: FileResolver,

    // mapping from name to loaded instances
    // pid to module mapping done inside kernel itself
    modules_list: std.StringHashMap(LoadedModule),
    kernel_allocator: std.mem.Allocator,

    pub fn create(file_resolver: FileResolver, kernel_allocator: std.mem.Allocator) Loader {
        return .{
            .file_resolver = file_resolver,
            .modules_list = std.StringHashMap(LoadedModule).init(kernel_allocator),
            .kernel_allocator = kernel_allocator,
        };
    }

    pub fn deinit(self: *Loader) void {
        self.modules_list.deinit();
    }

    fn get_shared_data(self: *Loader, module_name: []const u8, process_allocator: std.mem.Allocator, parser: *const Parser, xip: bool) !*LoadedSharedData {
        var maybe_existing_module = self.modules_list.getPtr(module_name);
        if (maybe_existing_module) |*loaded| {
            log.debug("Module is already loaded, propagating .text for: {s}", .{parser.name});
            loaded.*.users += 1;
            return loaded.*.shared_data;
        }
        log.debug("module doesn't exists, creating one for: {s}", .{parser.name});
        const shared_data = try LoadedSharedData.create(self.kernel_allocator, process_allocator, xip, parser);
        try self.modules_list.put(parser.name, .{
            .users = 1,
            .shared_data = shared_data,
        });
        return shared_data;
    }

    pub fn load_executable(self: *Loader, module: *const anyopaque, process_allocator: std.mem.Allocator) !Executable {
        const executable: Executable = .{
            .module = try Module.create(
                self.kernel_allocator,
                process_allocator,
                true,
            ),
        };
        try self.load_module(executable.module, module, process_allocator);
        return executable;
    }

    pub fn load_library(self: *Loader, module: *const anyopaque, process_allocator: std.mem.Allocator) !*Module {
        const library: *Module = try Module.create(self.kernel_allocator, process_allocator, true);
        try self.load_module(library, module, process_allocator);
        return library;
    }

    pub fn unload_module(self: *Loader, module: *Module) void {
        if (module.name) |name| {
            log.debug("Unloading module: {s}", .{name});
            const maybe_shared_data = self.modules_list.getPtr(name);
            if (maybe_shared_data) |*shared_data| {
                shared_data.*.users -= 1;
                if (shared_data.*.users == 0) {
                    log.debug("Removing shared data for: {s}", .{name});
                    shared_data.*.shared_data.destroy();
                    _ = self.modules_list.remove(name);
                }
            }
        } else {
            log.err("unloading unknown module", .{});
        }
    }

    fn load_module(self: *Loader, module: *Module, module_address: *const anyopaque, process_allocator: std.mem.Allocator) !void {
        log.debug("parsing header", .{});
        const header = self.process_header(module_address) catch |err| {
            log.err("Wrong magic cookie, not a yaff file", .{});
            return err;
        };
        print_header(header);
        const parser = Parser.create(header);
        parser.print();

        try module.set_name(parser.name);
        try self.import_child_modules(header, &parser, module);
        // if module is already loaded just data must be loaded
        const shared_data = try self.get_shared_data(parser.name, process_allocator, &parser, module.xip);
        module.add_shared_data(shared_data);
        try self.process_data(header, &parser, module);
        // module.exported_symbols = parser.exported_symbols;
        const init_ptr: [*]const u8 = @ptrFromInt(parser.init_address);
        try module.relocate_init(init_ptr[0..header.init_length], header);
        module.process_initializers();
        try self.process_symbol_table_relocations(&parser, module, header);
        try self.process_local_relocations(&parser, module);
        try self.process_data_relocations(&parser, module);
        log.debug(".text loaded at 0x{x}, size: {x} for: {s}", .{ @intFromPtr(module.get_text().ptr), module.get_text().len, module.name.? });
        log.debug(".plt  loaded at 0x{x}, size: {x} for: {s}", .{ @intFromPtr(module.get_plt().ptr), module.get_plt().len, module.name.? });
        log.debug(".data loaded at 0x{x}, size: {x} for: {s}", .{ @intFromPtr(module.get_data().ptr), module.get_data().len, module.name.? });
        log.debug(".bss  loaded at 0x{x}, size: {x} for: {s}", .{ @intFromPtr(module.get_bss().ptr), module.get_bss().len, module.name.? });
        log.debug(".got  loaded at 0x{x}, entr: {x} for: {s}", .{ @intFromPtr(module.get_got().ptr), module.get_got().len, module.name.? });

        if (header.entry != 0xffffffff and header.module_type == @intFromEnum(Type.Executable)) {
            var section: Section = .Unknown;
            const text_limit: usize = module.get_text().len;
            const init_limit: usize = text_limit + module.get_init().len;
            const data_limit: usize = init_limit + module.get_data().len;

            if (header.entry < text_limit) {
                section = .Code;
            } else if (header.entry < init_limit) {
                section = .Init;
            } else if (header.entry < data_limit) {
                section = .Data;
            } else {
                section = .Bss;
            }

            const base_address = try module.get_base_address(section);
            module.entry = .{
                .address = base_address + header.entry,
                .target_got_address = @intFromPtr(module.get_got().ptr),
            };
        }
    }

    fn import_child_modules(self: *Loader, header: *const Header, parser: *const Parser, module: *Module) LoaderError!void {
        if (header.external_libraries_amount == 0) {
            return;
        }

        var it = parser.imported_libraries.iter();
        var index: usize = 0;
        while (it) |library| : ({
            it = library.next();
            index += 1;
        }) {
            log.debug("loading child module '{s}'", .{library.data.name()});
            const maybe_address = self.file_resolver(library.data.name());
            if (maybe_address) |address| {
                const library_header = self.process_header(address) catch {
                    log.err("Incorrect 'YAFF' marking for '{s}'", .{library.data.name()});
                    return error.ChildLoadingFailure;
                };
                if (@as(Type, @enumFromInt(library_header.module_type)) != Type.Library) {
                    return LoaderError.DependencyIsNotLibrary;
                }
                const child = try Module.create(module.allocator, module.process_allocator, true);
                module.append_child(child);
                self.load_module(child, address, module.process_allocator) catch |err| {
                    log.err("Can't load child module '{s}': {s}", .{ library.data.name(), @errorName(err) });
                    return error.ChildLoadingFailure;
                };
            } else {
                log.err("Can't find child module '{s}'", .{library.data.name()});
                return LoaderError.DependencyNotFound;
            }
        }
    }

    fn process_data(_: Loader, header: *const Header, parser: *const Parser, module: *Module) !void {
        // unique data must be always copied to RAM
        module.unique_data = try LoadedUniqueData.create(
            module.allocator,
            module.process_allocator,
            header,
            parser,
        );

        if (header.got_plt_length != 0) {
            @panic("Support for .got.plt is not implemented yet");
        }
    }

    fn get_section_address_for_offset(module: *Module, header: *const Header, offset: usize) error{OffsetOutOfRange}!struct { section: usize, offset: usize } {
        const text_limit: usize = header.code_length;
        const init_offset: usize = text_limit + header.init_length;
        const plt_limit: usize = init_offset + header.plt_length;
        const data_limit: usize = plt_limit + header.data_length;
        const bss_limit: usize = data_limit + header.bss_length;
        const got_limit: usize = bss_limit + header.got_length;

        if (offset < text_limit) {
            return .{ .section = @intFromPtr(module.get_text().ptr), .offset = 0 };
        } else if (offset < init_offset) {
            return .{ .section = @intFromPtr(module.get_init().ptr), .offset = text_limit };
        } else if (offset < plt_limit) {
            return .{ .section = @intFromPtr(module.get_plt().ptr), .offset = init_offset };
        } else if (offset < data_limit) {
            return .{ .section = @intFromPtr(module.get_data().ptr), .offset = plt_limit };
        } else if (offset < bss_limit) {
            return .{ .section = @intFromPtr(module.get_bss().ptr), .offset = data_limit };
        } else if (offset < got_limit) {
            return .{ .section = @intFromPtr(module.get_got().ptr), .offset = bss_limit };
        } else {
            log.debug("Offset: {x} is out of range, text: {x}, init: {x}, plt: {x}, data: {x}, bss: {x}, got: {x}\n", .{ offset, text_limit, init_offset, plt_limit, data_limit, bss_limit, got_limit });
            return error.OffsetOutOfRange;
        }
    }

    fn process_symbol_table_relocations(self: Loader, parser: *const Parser, module: *Module, header: *const Header) !void {
        var got = module.get_got();
        log.debug("Processing symbol table relocations for GOT: {x}", .{@intFromPtr(got.ptr)});
        const maybe_init = self.find_symbol(module, "__start_data");
        if (maybe_init == null) {
            log.debug("[yasld] Can't find symbol '__start_data'", .{});
        }
        for (0..got.len) |i| {
            if (i < 3) {
                continue;
            } // skip first three entries, they are reserved for the loader itself

            const section_start = Loader.get_section_address_for_offset(module, header, got[i].symbol_offset) catch |err| {
                log.err("[yasld] Can't find section for GOT[{d}]: {s}", .{ i, @errorName(err) });
                return err;
            };
            const address = section_start.section + got[i].symbol_offset - section_start.offset;
            log.debug("Setting GOT[{d}] to: 0x{x}", .{ i, address });
            got[i].base_register = @intFromPtr(got.ptr);
            got[i].symbol_offset = address;
        }

        var number_of_function_pointer_relocations: usize = 0;
        var current_function_pointer_relocation_index: usize = 0;
        for (parser.symbol_table_relocations.relocations) |rel| {
            if (rel.function_pointer == 1) {
                number_of_function_pointer_relocations += 1;
            }
        }
        const maybe_unique_data = module.unique_data;
        if (maybe_unique_data) |unique| {
            try unique.allocate_thunks(number_of_function_pointer_relocations);
        }

        for (parser.symbol_table_relocations.relocations) |rel| {
            var maybe_symbol: ?*const Symbol = null;
            if (rel.function_pointer == 1) {
                maybe_symbol = parser.exported_symbols.element_at(rel.symbol_index);
                if (maybe_symbol == null) {
                    log.err("[yasld] Can't find symbol at index: {d}, size: {d}, exported: {d}", .{ rel.symbol_index, parser.imported_symbols.number_of_items, rel.is_exported_symbol });
                    return LoaderError.SymbolNotFound;
                }
                if (maybe_unique_data) |unique| {
                    if (unique.thunks) |thunks| {
                        if (!thunks.generated) {
                            const maybe_symbol_entry = self.find_symbol(module, maybe_symbol.?.name());
                            if (maybe_symbol_entry) |symbol_entry| {
                                const address = unique.generate_thunk(current_function_pointer_relocation_index, @intFromPtr(got.ptr), symbol_entry.address) catch |err| {
                                    log.err("[yasld] Can't generate thunk for symbol: '{s}': {s}", .{ maybe_symbol.?.name(), @errorName(err) });
                                    return err;
                                };
                                current_function_pointer_relocation_index += 1;
                                got[rel.index].symbol_offset = address;
                            }
                        }
                    } else {
                        const address = unique.get_thunk_address(current_function_pointer_relocation_index) catch |err| {
                            log.err("[yasld] Can't get thunk for symbol: '{s}': {s}", .{ maybe_symbol.?.name(), @errorName(err) });
                            return err;
                        };
                        current_function_pointer_relocation_index += 1;
                        got[rel.index].symbol_offset = address;
                    }
                }
                got[rel.index].base_register = @intFromPtr(got.ptr);
                continue;
            }
            if (rel.is_exported_symbol == 1) {
                maybe_symbol = parser.exported_symbols.element_at(rel.symbol_index);
            } else {
                maybe_symbol = parser.imported_symbols.element_at(rel.symbol_index);
            }
            if (maybe_symbol) |symbol| {
                const maybe_symbol_entry = self.find_symbol(module, symbol.name());
                if (maybe_symbol_entry) |symbol_entry| {
                    log.debug("Setting GOT[{d}] to: 0x{x} [{s}], exported: {d} -> GOT address: {x}", .{ rel.index, symbol_entry.address, symbol.name(), rel.is_exported_symbol, symbol_entry.target_got_address });
                    got[rel.index].symbol_offset = symbol_entry.address;
                    got[rel.index].base_register = symbol_entry.target_got_address;
                } else {
                    log.err("[yasld] Can't find symbol: '{s}'\n", .{symbol.name()});
                    return LoaderError.SymbolNotFound;
                }
            } else {
                log.err("[yasld] Can't find symbol at index: {d}, size: {d}, exported: {d}", .{ rel.symbol_index, parser.imported_symbols.number_of_items, rel.is_exported_symbol });
                return LoaderError.SymbolNotFound;
            }
        }

        if (maybe_unique_data) |shared| {
            shared.thunks.?.generated = true;
        }
    }

    fn find_symbol(_: Loader, module: *Module, name: []const u8) ?SymbolEntry {
        if (module.find_symbol(name)) |symbol| {
            return symbol;
        }

        return null;
    }

    fn process_local_relocations(_: Loader, parser: *const Parser, module: *Module) !void {
        var got = module.get_got();
        log.debug("Processing local relocations for GOT: 0x{x}", .{@intFromPtr(got.ptr)});
        for (parser.local_relocations.relocations) |rel| {
            const relocated_start_address: usize = try module.get_base_address(@enumFromInt(rel.section));
            const relocated = relocated_start_address + rel.target_offset;
            got[rel.index].symbol_offset = relocated;
            got[rel.index].base_register = @intFromPtr(got.ptr);

            log.debug("Patching GOT[{d}] to: 0x{x}, section: {s}, target_offset: 0x{x}", .{ rel.index, got[rel.index].symbol_offset, @tagName(@as(Section, @enumFromInt(rel.section))), rel.target_offset });
        }
    }

    fn process_data_relocations(_: Loader, parser: *const Parser, module: *Module) !void {
        for (parser.data_relocations.relocations) |rel| {
            var data_memory_address: usize = @intFromPtr(module.get_data().ptr);
            var rel_to = rel.to;
            log.debug("Processing data relocation: relto: {x} -> data: {x}", .{ rel_to, module.get_data().len });
            if (rel_to > module.get_data().len) {
                rel_to -= module.get_data().len;
                data_memory_address = @intFromPtr(module.get_bss().ptr);
                log.debug("Processing data relocation: relto: {x} -> bss: {x}", .{ rel_to, module.get_bss().len });
                if (rel_to > module.get_bss().len) {
                    rel_to -= module.get_bss().len;
                    data_memory_address = @intFromPtr(module.get_got().ptr);
                    log.debug("Processing data relocation: relto: {x} -> got: {x}", .{ rel_to, module.get_got().len * 8 });
                    if (rel_to > module.get_got().len * 8) {
                        return LoaderError.DataProcessingFailure;
                    }
                }
            }

            const address_to_change: usize = data_memory_address + rel_to;
            const target: *usize = @ptrFromInt(address_to_change);
            const base_address_from: usize = try module.get_base_address(@enumFromInt(rel.section));
            const address_from: usize = base_address_from + rel.from;
            log.debug("Patching from: 0x{x} to: 0x{x}, address_from: {x}, target: {x}", .{ rel.from, rel.to, address_from, @intFromPtr(target) });

            target.* = address_from;
        }
    }

    fn process_header(_: Loader, module_address: *const anyopaque) error{IncorrectSignature}!*const Header {
        const header: *const Header = @ptrCast(@alignCast(module_address));
        if (!std.mem.eql(u8, std.mem.asBytes(&header.magic), "YAFF")) {
            return error.IncorrectSignature;
        }
        return header;
    }
};

var loader_object: ?Loader = null;

pub fn init(file_resolver: anytype, allocator: std.mem.Allocator) void {
    loader_object = Loader.create(file_resolver, allocator);
}

pub fn deinit() void {
    if (loader_object) |*loader| {
        loader.deinit();
    }
}

pub fn get_loader() ?*Loader {
    if (loader_object) |*loader| {
        return loader;
    }
    return null;
}
