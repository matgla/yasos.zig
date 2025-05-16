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

    file_resolver: FileResolver,

    // mapping from name to loaded instances
    // pid to module mapping done inside kernel itself
    modules_list: std.AutoHashMap([]const u8, std.DoublyLinkedList),
    kernel_allocator: std.mem.Allocator,

    pub fn create(file_resolver: FileResolver, kernel_allocator: std.mem.Allocator) Loader {
        return .{
            .file_resolver = file_resolver,
            .modules_list = std.AutoHashMap(u32, std.DoublyLinkedList).init(kernel_allocator),
            .allocator = kernel_allocator,
        };
    }

    pub fn load_executable(self: Loader, module: *const anyopaque, stdout: anytype, process_allocator: std.mem.Allocator) !Executable {
        const executable: Executable = .{
            .module = try Module.create(
                self.allocator,
                process_allocator,
                true,
            ),
        };
        try self.load_module(executable.module, module, stdout);
        return executable;
    }

    pub fn load_library(self: Loader, module: *const anyopaque, stdout: anytype, process_allocator: std.mem.Allocator) !Module {
        var library: *Module = try Module.create(self.allocator, process_allocator, true);
        try self.load_module(&library, module, stdout);
        return library;
    }

    pub fn unload_module(self: *Loader, module: *Module) void {
        var maybe_list = self.modules_list.getPtr(module.name);
        if (maybe_list) |*list| {
            list.remove(module.list_node);
            module.destroy();
        }
        return error.ModuleNotFound;
    }

    fn is_already_loaded(self: *Loader, name: []const u8) bool {
        return self.modules_list.contains(name);
    }

    fn load_module(self: *Loader, module: *Module, module_address: *const anyopaque, stdout: anytype) !void {
        // stdout.write("[yasld] parsing header\n");
        const header = self.process_header(module_address) catch |err| {
            stdout.write("Wrong magic cookie, not a yaff file\n");
            return err;
        };
        print_header(header, stdout);

        const parser = Parser.create(header, stdout);
        // parser.print(stdout);

        try module.set_name(parser.name);

        try self.import_child_modules(header, &parser, module, stdout);

        // if module is already loaded just data must be loaded
        const maybe_existing_module = self.modules_list.getPtr(parser.name);
        if (maybe_existing_module) |*loaded| {
            stdout.print("Module is already loaded, propagating .text for: {s}", .{parser.name});
            if (loaded.shared_data) |*data| {
                module.add_shared_data(data);
            } else {
                stdout.print("Module '{s}' is already loaded, but shared data missing\n", .{parser.name});
                return LoaderError.DataProcessingFailure;
            }
        }

        // import modules
        try self.process_data(header, &parser, module, stdout);
        module.exported_symbols = parser.exported_symbols;

        const init_ptr: [*]const u8 = @ptrFromInt(parser.init_address);
        try module.relocate_init(init_ptr[0..header.init_length]);
        module.process_initializers(stdout);

        try self.process_symbol_table_relocations(&parser, module, stdout);
        try self.process_local_relocations(&parser, module);
        try self.process_data_relocations(&parser, module, stdout);

        // stdout.print("[yasld] GOT loaded at 0x{x}\n", .{@intFromPtr(module.get_got().ptr)});
        stdout.print("[yasld] text loaded at 0x{x} for: {s}\n", .{ @intFromPtr(module.program.?.ptr), module.name.? });

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
    fn import_child_modules(self: Loader, header: *const Header, parser: *const Parser, module: *Module, stdout: anytype) LoaderError!void {
        if (header.external_libraries_amount == 0) {
            return;
        }

        try module.allocate_modules(header.external_libraries_amount);

        var it = parser.imported_libraries.iter();
        var index: usize = 0;
        while (it) |library| : ({
            it = library.next();
            index += 1;
        }) {
            stdout.print("[yasld] loading child module '{s}'\n", .{library.data.name()});
            const maybe_address = self.file_resolver(library.data.name());
            if (maybe_address) |address| {
                const library_header = self.process_header(address) catch {
                    stdout.print("Incorrect 'YAFF' marking for '{s}'\n", .{library.data.name()});
                    return error.ChildLoadingFailure;
                };
                if (@as(Type, @enumFromInt(library_header.module_type)) != Type.Library) {
                    return LoaderError.DependencyIsNotLibrary;
                }

                self.load_module(&module.imported_modules.items[index], address, stdout) catch |err| {
                    stdout.print("Can't load child module '{s}': {s}\n", .{ library.data.name(), @errorName(err) });
                    return error.ChildLoadingFailure;
                };
            } else {
                stdout.print("Can't find child module '{s}'\n", .{library.data.name()});
                return LoaderError.DependencyNotFound;
            }
        }
    }

    fn process_data(_: Loader, header: *const Header, parser: *const Parser, module: *Module, stdout: anytype) !void {
        // _ = stdout;
        if (module.shared_data == null) {
            // we are first module that uses that data, initialization must be done
            const shared_data = LoadedSharedData.create(module.allocator, module.list_node, module.xip);
            if (module.xip) {
                const text = parser.get_text();
                const init = parser.get_init();
                const plt = parser.get_plt();
                shared_data.*.text = text;
                shared_data.*.init = init;
                shared_data.*.plt = plt;
                module.shared_data = shared_data;
            } else {}
        }

        // unique data must be always copied to RAM
        module.unique_data = LoadedUniqueData.create(
            module.allocator,
            module.process_allocator,
            header,
            parser,
        );

        const plt_start = header.code_length + header.init_length;
        const plt_end = plt_start + header.plt_length;
        const plt_data = parser.get_plt();
        stdout.print("[yasld] copying .plt from: 0x{x} to: 0x{x}, size: {d}\n", .{ @intFromPtr(plt_data.ptr), @intFromPtr(&module.program.?[plt_start]), plt_data.len });
        @memcpy(module.program.?[plt_start..plt_end], plt_data);

        const data_start = plt_end;
        const data_end = data_start + header.data_length;

        stdout.print("[yasld] copying .data from: 0x{x} to: 0x{x}, size: {d}\n", .{ @intFromPtr(data_initializer.ptr), @intFromPtr(&module.program.?[data_start]), data_initializer.len });
        @memcpy(module.program.?[data_start..data_end], data_initializer);
        const bss_start = data_end;
        const bss_end = bss_start + header.bss_length;

        @memset(module.program.?[bss_start..bss_end], 0);

        // const got_start = bss_end;
        stdout.print("[yasld] intializing .got at: 0x{x}\n", .{@intFromPtr(&module.program.?[bss_end])});
        // const got_end = got_start + header.got_length;
        // const got_data = parser.get_got();
        // stdout.print("[yasld] copying .got from: 0x{x} to: 0x{x}, size: {d}\n", .{ @intFromPtr(got_data.ptr), @intFromPtr(&module.program.?[got_start]), got_data.len });
        // @memcpy(module.program.?[got_start..got_end], got_data);

        if (header.got_plt_length != 0) {
            @panic("Support for .got.plt is not implemented yet");
        }
    }

    fn process_symbol_table_relocations(self: Loader, parser: *const Parser, module: *Module, stdout: anytype) !void {
        var got = module.get_got();
        const text = module.get_text();
        const module_start = @intFromPtr(text.ptr);
        const maybe_init = self.find_symbol(module, "__start_data");
        if (maybe_init == null) {
            stdout.print("[yasld] Can't find symbol '__start_data'\n", .{});
        }

        for (0..got.len) |i| {
            const address = module_start + got[i].symbol_offset;
            stdout.print("[yasld] Setting GOT[{d}] to: 0x{x}\n", .{ i, address });
            got[i].base_register = @intFromPtr(got.ptr);
            got[i].symbol_offset = address;
        }

        for (parser.symbol_table_relocations.relocations) |rel| {
            var maybe_symbol: ?*const Symbol = null;
            if (rel.is_exported_symbol == 1) {
                maybe_symbol = parser.exported_symbols.element_at(rel.symbol_index);
            } else {
                maybe_symbol = parser.imported_symbols.element_at(rel.symbol_index);
            }
            if (maybe_symbol) |symbol| {
                const maybe_symbol_entry = self.find_symbol(module, symbol.name());
                if (maybe_symbol_entry) |symbol_entry| {
                    stdout.print("[yasld] Setting GOT[{d}] to: 0x{x} [{s}], exported: {d} -> GOT address: {x}\n", .{ rel.index, symbol_entry.address, symbol.name(), rel.is_exported_symbol, symbol_entry.target_got_address });
                    got[rel.index].symbol_offset = symbol_entry.address;
                    got[rel.index].base_register = symbol_entry.target_got_address;
                } else {
                    stdout.print("[yasld] Can't find symbol: '{s}'\n", .{symbol.name()});
                    return LoaderError.SymbolNotFound;
                }
            } else {
                stdout.print("[yasld] Can't find symbol at index: {d}, size: {d}, exported: {d}\n", .{ rel.symbol_index, parser.imported_symbols.number_of_items, rel.is_exported_symbol });
                // return LoaderError.SymbolNotFound;
            }
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
        for (parser.local_relocations.relocations) |rel| {
            const relocated_start_address: usize = try module.get_base_address(@enumFromInt(rel.section));
            const relocated = relocated_start_address + rel.target_offset;
            got[rel.index].symbol_offset = relocated;
            got[rel.index].base_register = @intFromPtr(got.ptr);
        }
    }

    fn process_data_relocations(_: Loader, parser: *const Parser, module: *Module, stdout: anytype) !void {
        _ = stdout;
        const data_memory = module.get_data();
        for (parser.data_relocations.relocations) |rel| {
            const address_to_change: usize = @intFromPtr(data_memory.ptr) + rel.to;
            const target: *usize = @ptrFromInt(address_to_change);
            const base_address_from: usize = try module.get_base_address(@enumFromInt(rel.section));
            const address_from: usize = base_address_from + rel.from;
            // stdout.print("Patching from: 0x{x} to: 0x{x}, base: {x}\n", .{ rel.from, rel.to, base_address_from });

            target.* = address_from;
        }
    }

    fn process_header(_: Loader, module_address: *const anyopaque) error{IncorrectSignature}!*const Header {
        const header: *const Header = @ptrCast(@alignCast(module_address));
        if (!std.mem.eql(u8, std.mem.asBytes(&header.marker), "YAFF")) {
            return error.IncorrectSignature;
        }
        return header;
    }
};
