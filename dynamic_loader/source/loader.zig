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
const header_module = @import("header.zig");
const Header = header_module.Header;
const Architecture = header_module.Architecture;
const Features = header_module.Features;
const FloatAbi = header_module.FloatAbi;
const Fpu = header_module.Fpu;
const print_header = header_module.print_header;
const Module = @import("module.zig").Module;
const refcount = @import("refcount.zig");
const Parser = @import("parser.zig").Parser;
const Type = @import("header.zig").Type;
const Section = @import("section.zig").Section;
const Symbol = @import("symbol.zig").Symbol;
const SymbolEntry = @import("module.zig").SymbolEntry;
const LoadedSharedData = @import("module.zig").LoadedSharedData;
const LoadedUniqueData = @import("module.zig").LoadedUniqueData;
// Temporary load-phase accounting; see load_profile.zig.
const profile = @import("load_profile.zig");

const log = std.log.scoped(.yasld);

/// Whether every completed load prints its section bases at info level. Off by
/// default: the `.yasld` scope is pinned to info in `std_options`, so the line
/// goes out over the console UART, and `Uart.write` busy-waits for TX space —
/// with three or four modules per spawn that is milliseconds of blocking serial
/// on every exec, paid by a suite that spawns thousands of times.
///
/// Nothing is lost by default. The same bases are dumped on a fault
/// (`dump_fault_maps`, source/kernel/modules.zig) and readable on demand from
/// /proc/<pid>/maps. The kernel turns this back on for a profiling build, where
/// the line is wanted inline with the `load kind=` timings.
var emit_load_map: bool = false;

/// Called by the kernel at loader init (source/kernel/modules.zig) with whatever
/// the perf-profiling config says.
pub fn set_load_map_logging(enable: bool) void {
    emit_load_map = enable;
}

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

/// Why an image cannot be run here. Every one of these means "this file is not
/// executable on this machine", which the kernel reports as ENOEXEC.
pub const ImageError = error{
    /// Not a YAFF file at all.
    IncorrectSignature,
    /// On-disk layout from a toolchain this loader does not know.
    UnsupportedYaffVersion,
    /// No architecture section, so the image makes no claim about what it
    /// needs and there is nothing to check it against.
    MissingArchSection,
    /// Built for a different instruction set.
    UnsupportedArchitecture,
    /// Built for a different floating point calling convention.
    UnsupportedFloatAbi,
    /// Needs hardware this part does not have, or does not have enabled.
    UnsupportedCpuFeatures,
};

/// What this machine can execute. Supplied by the kernel, which is the only
/// side that knows the part it is running on; the loader itself is built once
/// per architecture and carries no board knowledge.
pub const MachineProfile = struct {
    arch: Architecture,
    /// Calling convention the system's libraries were built with.
    float_abi: FloatAbi,
    /// Hardware present *and* enabled -- an FPU the kernel never switched on
    /// at CPACR must not be advertised here.
    features: Features,
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
    machine: MachineProfile,

    pub fn create(file_resolver: FileResolver, kernel_allocator: std.mem.Allocator, machine: MachineProfile) Loader {
        return .{
            .file_resolver = file_resolver,
            .modules_list = std.StringHashMap(LoadedModule).init(kernel_allocator),
            .kernel_allocator = kernel_allocator,
            .machine = machine,
        };
    }

    pub fn deinit(self: *Loader) void {
        self.modules_list.deinit();
    }

    fn get_shared_data(self: *Loader, module_name: []const u8, process_allocator: std.mem.Allocator, parser: *const Parser, xip: bool) !*LoadedSharedData {
        var maybe_existing_module = self.modules_list.getPtr(module_name);
        if (maybe_existing_module) |*loaded| {
            log.debug("Module is already loaded, propagating .text for: {s}", .{parser.name});
            refcount.acquire(&loaded.*.users);
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
                // Fused with the decrement. Separate, two unloads racing on the
                // last two users both see zero and both destroy. Note this is
                // still not sufficient on its own -- a concurrent
                // `get_shared_data` can resurrect the pointer between this
                // decision and the `remove` below; that needs `loader_lock`.
                if (refcount.release(&shared_data.*.users)) {
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
        var _t = profile.now_us();
        const header = self.process_header(module_address) catch |err| {
            log.err("Refusing to load module: {s}", .{@errorName(err)});
            return err;
        };
        const parser = Parser.create(header);
        // Both of these only emit `log.debug`, but their loops are driven by
        // `ItemTable.iter()`, which calls `size()` -- a full strlen-strided walk
        // -- to find its end pointer. The bodies compile out at the pinned
        // `.yasld` level; the walks do not, because the trip count is a
        // pointer chase LLVM cannot prove finite. Gate the calls instead.
        if (comptime std.log.logEnabled(.debug, .yasld)) {
            print_header(header);
            parser.print();
        }

        // Carry the per-image stack/heap profile so exec can bound the process
        // to what the program declared (0xFFFFFFFF = OS default).
        module.stack_size = header.stack_size;
        module.heap_size = header.heap_size;
        // RELRO: size of the shared XIP rodata prefix (see resolve_data_offset).
        module.const_rodata_length = header.const_rodata_length;

        try module.set_name(parser.name);
        profile.account(.parse, _t);

        _t = profile.now_us();
        try self.import_child_modules(header, &parser, module);
        profile.account(.children, _t);

        // if module is already loaded just data must be loaded
        _t = profile.now_us();
        const shared_data = try self.get_shared_data(parser.name, process_allocator, &parser, module.xip);
        module.add_shared_data(shared_data);
        profile.account(.shared_data, _t);

        // Split into alloc/copy inside LoadedUniqueData.create.
        try self.process_data(header, &parser, module);

        // module.exported_symbols = parser.exported_symbols;
        _t = profile.now_us();
        const init_ptr: [*]const u8 = @ptrFromInt(parser.init_address);
        try module.relocate_init(init_ptr[0..header.init_length], header);
        module.process_initializers();
        profile.account(.init_relocate, _t);

        // Pre-count function pointer thunks needed for both symbol table and local relocations
        var symbol_table_fn_ptr_count: usize = 0;
        for (parser.symbol_table_relocations.relocations) |rel| {
            if (rel.function_pointer == 1) {
                symbol_table_fn_ptr_count += 1;
            }
        }
        var local_fn_ptr_count: usize = 0;
        for (parser.local_relocations.relocations) |rel| {
            if (@as(Section, @enumFromInt(rel.section)) == .Code) {
                local_fn_ptr_count += 1;
            }
        }
        var data_fn_ptr_count: usize = 0;
        for (parser.data_relocations.relocations) |rel| {
            if (@as(Section, @enumFromInt(rel.section)) == .Unknown) {
                data_fn_ptr_count += 1;
            }
        }
        const total_fn_ptr_thunks = symbol_table_fn_ptr_count + local_fn_ptr_count + data_fn_ptr_count;
        log.debug("Total function pointer thunks needed: {d} (symbol_table: {d}, local: {d}, data: {d})", .{ total_fn_ptr_thunks, symbol_table_fn_ptr_count, local_fn_ptr_count, data_fn_ptr_count });
        if (total_fn_ptr_thunks > 0) {
            if (module.unique_data) |unique| {
                try unique.allocate_thunks(total_fn_ptr_thunks);
            }
        }

        _t = profile.now_us();
        try self.process_symbol_table_relocations(&parser, module, header);
        profile.account(.symbol_relocations, _t);

        _t = profile.now_us();
        try self.process_local_relocations(&parser, module, symbol_table_fn_ptr_count);
        profile.account(.local_relocations, _t);

        _t = profile.now_us();
        try self.process_data_relocations(&parser, module, symbol_table_fn_ptr_count + local_fn_ptr_count);
        profile.account(.data_relocations, _t);

        _t = profile.now_us();
        try self.process_copy_relocations(&parser, module);
        profile.account(.copy_relocations, _t);

        // Mark thunks as generated after all relocation processing is complete
        if (module.unique_data) |unique| {
            if (unique.thunks) |thunks| {
                thunks.generated = true;
            }
        }

        // There is deliberately no per-section ".text/.plt/.data/.bss/.got
        // loaded at 0x…" line here any more. Those addresses are available
        // on-demand from /proc/<pid>/maps (source/kernel/process/maps_file.zig),
        // which is what scripts/yasld_gdb.py reads; printing five lines per
        // module on every spawn cost two blocking UART writes each, could
        // corrupt the binary zmodem stream used for serial file uploads, and
        // showed up in screen recordings of the console.
        // Concise one-line load summary: the runtime base map that symbolizes
        // fault PCs against the on-disk ELFs (module .text/.data/.got bases).
        // Correlate with the adjacent "yasld-bench ... pid=N" line in
        // modules.zig to attach a pid. Gated by `emit_load_map` — see there for
        // why this does not go out on every spawn by default.
        if (emit_load_map) {
            log.info("loaded '{s}': .text=0x{x}(+0x{x}) .data=0x{x} .got=0x{x}", .{
                module.name.?,
                @intFromPtr(module.get_text().ptr),
                module.get_text().len,
                @intFromPtr(module.get_data().ptr),
                @intFromPtr(module.get_got().ptr),
            });
        }

        // Dump GOT entries and .data words for debugging function pointer resolution
        // {
        //     const got = module.get_got();
        //     const max_dump = if (got.len < 20) got.len else 20;
        //     for (0..max_dump) |gi| {
        //         log.err("  GOT[{d}]: sym=0x{x} base=0x{x} [{s}]", .{ gi, got[gi].symbol_offset, got[gi].base_register, module.name.? });
        //     }
        //     const data = module.get_data();
        //     const data_words = data.len / 4;
        //     const max_data = if (data_words < 16) data_words else 16;
        //     const data_as_u32: [*]const u32 = @ptrCast(@alignCast(data.ptr));
        //     for (0..max_data) |di| {
        //         log.err("  .data[{d}]: 0x{x} [{s}]", .{ di, data_as_u32[di], module.name.? });
        //     }
        // }

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

            module.entry = .{
                .address = try module.address_in_section(section, header.entry),
                .target_got_address = @intFromPtr(module.get_got().ptr),
            };
        }
    }

    fn import_child_modules(self: *Loader, header: *const Header, parser: *const Parser, module: *Module) (LoaderError || ImageError)!void {
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
                // Propagated as-is rather than folded into ChildLoadingFailure:
                // a dependency built for another machine is the same "cannot
                // execute this here" answer as an executable built for one, and
                // the caller turns it into ENOEXEC.
                const library_header = self.process_header(address) catch |err| {
                    log.err("Refusing to load '{s}': {s}", .{ library.data.name(), @errorName(err) });
                    return err;
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

    fn get_section_address_for_offset(module: *Module, header: *const Header, offset: usize) error{OffsetOutOfRange}!struct { section: usize, offset: usize, is_code: bool } {
        const text_limit: usize = header.code_length;
        const init_offset: usize = text_limit + header.init_length;
        const plt_limit: usize = init_offset + header.plt_length;
        const data_limit: usize = plt_limit + header.data_length;
        const bss_limit: usize = data_limit + header.bss_length;
        const got_limit: usize = bss_limit + header.got_length;

        if (offset < text_limit) {
            return .{ .section = @intFromPtr(module.get_text().ptr), .offset = 0, .is_code = true };
        } else if (offset < init_offset) {
            return .{ .section = @intFromPtr(module.get_init().ptr), .offset = text_limit, .is_code = true };
        } else if (offset < plt_limit) {
            return .{ .section = @intFromPtr(module.get_plt().ptr), .offset = init_offset, .is_code = true };
        } else if (offset < data_limit) {
            // RELRO: the data region is [shared rodata | per-process data]. An
            // offset within the rodata prefix resolves to the shared XIP rodata;
            // the rest to the per-process data buffer (whose offset space starts
            // const_rodata_length later).
            const data_region_offset = offset - plt_limit;
            if (module.const_rodata_length > 0 and data_region_offset < module.const_rodata_length) {
                if (module.shared_data) |shared| {
                    if (shared.rodata) |rodata| {
                        return .{ .section = @intFromPtr(rodata.ptr), .offset = plt_limit, .is_code = false };
                    }
                }
            }
            return .{ .section = @intFromPtr(module.get_data().ptr), .offset = plt_limit + module.const_rodata_length, .is_code = false };
        } else if (offset < bss_limit) {
            return .{ .section = @intFromPtr(module.get_bss().ptr), .offset = data_limit, .is_code = false };
        } else if (offset < got_limit) {
            return .{ .section = @intFromPtr(module.get_got().ptr), .offset = bss_limit, .is_code = false };
        } else {
            log.debug("Offset: {x} is out of range, text: {x}, init: {x}, plt: {x}, data: {x}, bss: {x}, got: {x}\n", .{ offset, text_limit, init_offset, plt_limit, data_limit, bss_limit, got_limit });
            return error.OffsetOutOfRange;
        }
    }

    /// Name of a module whose GOT resolution should be reported at load time.
    /// The fault under investigation has a correct binary, a correctly sized
    /// GOT and correct thunks, yet the module's own writes do not land in its
    /// .data/.bss -- so the missing fact is which *symbol* owns which slot,
    /// which the loader computes and then only whispers at a log level nobody
    /// builds with. Matching one name keeps this to a handful of serial lines
    /// for one process instead of every load in the system.
    const trace_got_for: ?[]const u8 = null;

    fn should_trace_got(module: *Module) bool {
        const want = trace_got_for orelse return false;
        const name = module.name orelse return false;
        return std.mem.indexOf(u8, name, want) != null;
    }

    fn process_symbol_table_relocations(self: Loader, parser: *const Parser, module: *Module, header: *const Header) !void {
        var got = module.get_got();
        const trace_got = should_trace_got(module);
        log.debug("Processing symbol table relocations for GOT: {x}", .{@intFromPtr(got.ptr)});
        // A `find_symbol(module, "__start_data")` probe used to sit here whose
        // only consumer was a log body that compiles out at the pinned `.yasld`
        // level. The call itself did not: the symbol is absent, so it walked
        // every export table in the tree -- ~900 strided entries per module
        // load -- and discarded the answer.
        for (0..got.len) |i| {
            if (i < 3) {
                continue;
            } // skip first three entries, they are reserved for the loader itself

            // GOT entries with offset 0 are unresolved external symbols that
            // will be patched by symbol table relocations (Phase B below).
            // Converting offset 0 here would incorrectly map them to _start.
            if (got[i].symbol_offset == 0) {
                continue;
            }

            const raw_offset = got[i].symbol_offset;
            const section_start = Loader.get_section_address_for_offset(module, header, got[i].symbol_offset) catch |err| {
                log.err("[yasld] Can't find section for GOT[{d}]: {s}", .{ i, @errorName(err) });
                return err;
            };
            const address = section_start.section + got[i].symbol_offset - section_start.offset;
            log.debug("Setting GOT[{d}] to: 0x{x}", .{ i, address });
            got[i].base_register = @intFromPtr(got.ptr);
            // Cortex-M executes only Thumb code. Code addresses resolved here
            // (e.g. labels from goto *&&label that have no local relocation)
            // need bit 0 set so that BX does not fault.
            got[i].symbol_offset = if (section_start.is_code) address | 1 else address;
            log.debug("PhaseA GOT[{d}]: raw=0x{x} -> 0x{x}, is_code={}", .{ i, raw_offset, got[i].symbol_offset, section_start.is_code });
            if (trace_got) {
                log.err("gotmap A[{d}] raw=0x{x} -> 0x{x} code={}", .{ i, raw_offset, got[i].symbol_offset, section_start.is_code });
            }
        }

        var current_function_pointer_relocation_index: usize = 0;
        const maybe_unique_data = module.unique_data;

        for (parser.symbol_table_relocations.relocations) |rel| {
            var maybe_symbol: ?*const Symbol = null;
            if (rel.function_pointer == 1) {
                if (rel.is_exported_symbol == 1) {
                    maybe_symbol = parser.exported_symbols.element_at(rel.symbol_index);
                } else {
                    maybe_symbol = parser.imported_symbols.element_at(rel.symbol_index);
                }
                if (maybe_symbol == null) {
                    log.err("[yasld] Can't find symbol at index: {d}, size: {d}, exported: {d}", .{ rel.symbol_index, parser.imported_symbols.number_of_items, rel.is_exported_symbol });
                    return LoaderError.SymbolNotFound;
                }
                if (maybe_unique_data) |unique| {
                    if (unique.thunks) |thunks| {
                        if (!thunks.generated) {
                            const maybe_symbol_entry = self.find_symbol(module, maybe_symbol.?.name());
                            if (maybe_symbol_entry) |symbol_entry| {
                                const address = unique.generate_thunk(current_function_pointer_relocation_index, symbol_entry.target_got_address, symbol_entry.address) catch |err| {
                                    log.err("[yasld] Can't generate thunk for symbol: '{s}': {s}", .{ maybe_symbol.?.name(), @errorName(err) });
                                    return err;
                                };
                                log.debug("Setting GOT[{d}] to symtab thunk: 0x{x} [{s}], target: 0x{x}, r9: 0x{x}, thunk_idx: {d}", .{ rel.index, address, maybe_symbol.?.name(), symbol_entry.address, symbol_entry.target_got_address, current_function_pointer_relocation_index });
                                if (trace_got) {
                                    log.err("gotmap T[{d}] sym='{s}' thunk=0x{x} fn=0x{x} idx={d}", .{ rel.index, maybe_symbol.?.name(), address, symbol_entry.address, current_function_pointer_relocation_index });
                                }
                                current_function_pointer_relocation_index += 1;
                                got[rel.index].symbol_offset = address;
                            } else if (maybe_symbol.?.weak == 1) {
                                // MUST be NULL, not a trap address. A weak
                                // undefined symbol's address is 0 by definition
                                // and `if (f) f();` is the whole point of weak
                                // linkage -- tests2/104_inline declares 14 of
                                // these __attribute__((weak)) and asserts their
                                // addresses print as 0. Pointing them at a
                                // diagnostic stub makes every such test see a
                                // non-null pointer and call it.
                                log.debug("Weak function pointer symbol '{s}' not found, resolving to NULL", .{maybe_symbol.?.name()});
                                // Gated: unresolved weak function pointers are
                                // NORMAL. C99 `inline` without `extern` emits no
                                // definition, so tests2/104_inline alone has 14
                                // of them, none ever called. Logging each at err
                                // level put loader chatter into the program's
                                // output and failed a test that ran correctly.
                                if (trace_got) {
                                    log.err("gotmap NULLFP[{d}] sym='{s}' -> unresolved trap", .{ rel.index, maybe_symbol.?.name() });
                                }
                                got[rel.index].symbol_offset = 0;
                            } else {
                                log.err("[yasld] Can't find function pointer symbol: '{s}'", .{maybe_symbol.?.name()});
                                return LoaderError.SymbolNotFound;
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
                // PLT calls (R_ARM_JUMP_SLOT) and ordinary imported symbols are
                // both resolved eagerly here, filling the GOT entry with
                // {symbol_offset = fn addr, base_register = target R9}. Every
                // imported call relocates to `bl PLT[n]` at link time (R_ARM_CALL
                // -> AUTO_GOTPLT_ENTRY), and that shared .plt stub lives in XIP
                // flash; on each call it loads both GOT words and switches R9,
                // so a per-process dispatch thunk is unnecessary. Dropping the
                // old per-PLT-import lazy-resolver thunk saves ~6.6 KiB/process
                // for toybox (208 imports x 32 B) plus the LazyBindingInfo
                // descriptors. Trade-off: all imports resolve at load instead of
                // first call (lazy binding deferred to a future PLT-fallback).
                const maybe_symbol_entry = self.find_symbol(module, symbol.name());
                if (maybe_symbol_entry) |symbol_entry| {
                    log.debug("Setting GOT[{d}] to: 0x{x} [{s}], exported: {d} -> GOT address: {x}", .{ rel.index, symbol_entry.address, symbol.name(), rel.is_exported_symbol, symbol_entry.target_got_address });
                    if (trace_got) {
                        log.err("gotmap B[{d}] sym='{s}' -> 0x{x} base=0x{x} exported={d}", .{ rel.index, symbol.name(), symbol_entry.address, symbol_entry.target_got_address, rel.is_exported_symbol });
                    }
                    got[rel.index].symbol_offset = symbol_entry.address;
                    got[rel.index].base_register = symbol_entry.target_got_address;
                } else if (symbol.weak == 1) {
                    log.debug("Weak symbol '{s}' not found, resolving to NULL", .{symbol.name()});
                    got[rel.index].symbol_offset = 0;
                    got[rel.index].base_register = 0;
                } else {
                    log.err("[yasld] Can't find symbol: '{s}'\n", .{symbol.name()});
                    return LoaderError.SymbolNotFound;
                }
            } else {
                log.err("[yasld] Can't find symbol at index: {d}, size: {d}, exported: {d}", .{ rel.symbol_index, parser.imported_symbols.number_of_items, rel.is_exported_symbol });
                return LoaderError.SymbolNotFound;
            }
        }
    }

    fn find_symbol(_: Loader, module: *Module, name: []const u8) ?SymbolEntry {
        if (module.find_symbol(name)) |symbol| {
            return symbol;
        }

        return null;
    }

    fn process_local_relocations(_: Loader, parser: *const Parser, module: *Module, thunk_start_index: usize) !void {
        var got = module.get_got();
        log.debug("Processing local relocations for GOT: 0x{x}", .{@intFromPtr(got.ptr)});
        var thunk_index = thunk_start_index;
        const maybe_unique_data = module.unique_data;

        for (parser.local_relocations.relocations) |rel| {
            const section: Section = @enumFromInt(rel.section);
            // RELRO-aware: a DATA target offset < const_rodata_length resolves to
            // the shared rodata (this is also how the rodata anchor slot, emitted
            // as {DATA, 0}, is pointed at the shared rodata base).
            const relocated = try module.address_in_section(section, rel.target_offset);

            if (section == .Code) {
                // Code section local relocations are function pointers.
                // Wrap them in thunks so that r9 is set to the owning module's
                // GOT when the function is called back from another module.
                if (maybe_unique_data) |unique| {
                    if (unique.thunks) |thunks| {
                        if (!thunks.generated) {
                            // Ensure Thumb bit is set for Cortex-M function pointers
                            var fn_address = relocated;
                            if (fn_address & 1 == 0) {
                                fn_address |= 1;
                            }
                            const address = unique.generate_thunk(thunk_index, @intFromPtr(got.ptr), fn_address) catch |err| {
                                log.err("[yasld] Can't generate local thunk for GOT[{d}]: {s}", .{ rel.index, @errorName(err) });
                                return err;
                            };
                            log.debug("Setting GOT[{d}] to local thunk: 0x{x}, target: 0x{x}, r9: 0x{x}, thunk_idx: {d}", .{ rel.index, address, fn_address, @intFromPtr(got.ptr), thunk_index });
                            got[rel.index].symbol_offset = address;
                            if (should_trace_got(module)) {
                                log.err("gotmap L[{d}] thunk=0x{x} fn=0x{x} idx={d}", .{ rel.index, address, fn_address, thunk_index });
                            }
                            thunk_index += 1;
                        } else {
                            const address = unique.get_thunk_address(thunk_index) catch |err| {
                                log.err("[yasld] Can't get local thunk for GOT[{d}]: {s}", .{ rel.index, @errorName(err) });
                                return err;
                            };
                            got[rel.index].symbol_offset = address;
                            thunk_index += 1;
                        }
                    }
                }
            } else {
                got[rel.index].symbol_offset = relocated;
            }

            got[rel.index].base_register = @intFromPtr(got.ptr);
            log.debug("Patching GOT[{d}] to: 0x{x}, section: {s}, target_offset: 0x{x}", .{ rel.index, got[rel.index].symbol_offset, @tagName(section), rel.target_offset });
        }
    }

    fn process_data_relocations(_: Loader, parser: *const Parser, module: *Module, thunk_start_index: usize) !void {
        var thunk_index = thunk_start_index;
        const maybe_unique_data = module.unique_data;

        for (parser.data_relocations.relocations) |rel| {
            const from_section: Section = @enumFromInt(rel.section);

            if (from_section == .Unknown) {
                // GOT-indirect: imported function pointer.
                // rel.from is a GOT entry index.  The GOT entry was already
                // resolved by process_symbol_table_relocations.
                const got = module.get_got();
                if (rel.from >= got.len) {
                    log.err("DataReloc GOT-indirect: from={d} exceeds GOT len={d}", .{ rel.from, got.len });
                    return LoaderError.DataProcessingFailure;
                }
                const got_entry = got[rel.from];

                // Patch site lives in the per-process [data][bss][got] buffer;
                // resolve_data_offset maps the linker offset (which includes the
                // shared-rodata prefix) into it (offset - const_rodata_length).
                const address_to_change: usize = module.resolve_data_offset(rel.to);
                const target: *usize = @ptrFromInt(address_to_change);

                if (got_entry.base_register != @intFromPtr(got.ptr)) {
                    // Cross-module function pointer: create a thunk that
                    // switches r9 to the target module's GOT.
                    if (maybe_unique_data) |unique| {
                        if (unique.thunks) |thunks| {
                            var fn_address = got_entry.symbol_offset;
                            if (fn_address & 1 == 0) {
                                fn_address |= 1;
                            }
                            if (!thunks.generated) {
                                const address = unique.generate_thunk(thunk_index, got_entry.base_register, fn_address) catch |err| {
                                    log.err("[yasld] Can't generate data thunk for GOT[{d}]: {s}", .{ rel.from, @errorName(err) });
                                    return err;
                                };
                                target.* = address;
                                thunk_index += 1;
                            } else {
                                const address = unique.get_thunk_address(thunk_index) catch |err| {
                                    log.err("[yasld] Can't get data thunk for GOT[{d}]: {s}", .{ rel.from, @errorName(err) });
                                    return err;
                                };
                                target.* = address;
                                thunk_index += 1;
                            }
                        }
                    }
                } else {
                    // Same module: write function address directly (no thunk needed)
                    target.* = got_entry.symbol_offset;
                }
                continue;
            }

            // Patch site is in the per-process [data][bss][got] buffer.
            const address_to_change: usize = module.resolve_data_offset(rel.to);
            const target: *usize = @ptrFromInt(address_to_change);
            // Target (pointer value): DATA goes through the rodata-aware resolver
            // (a pointer into shared rodata, e.g. a const string, lands there);
            // CODE/Init keep their base + offset.
            var address_from: usize = try module.address_in_section(from_section, rel.from);

            // Cortex-M executes only Thumb code. Some relocation producers emit
            // even code symbol addresses for function pointers (for example
            // entrypoint symbols), which causes faults on indirect branches.
            // Normalize code/init pointers to Thumb entry addresses.
            if ((from_section == .Code or from_section == .Init) and (address_from & 1) == 0) {
                address_from += 1;
            }

            // If this same function is also reachable through the GOT, that GOT
            // entry was given a thunk by process_local_relocations. Writing the
            // raw address here would make the two pointers to one function
            // compare unequal, which C forbids (gcc-torture 930608-1). Reuse the
            // thunk that already exists; do not mint a new one, since only GOT
            // and imported-pointer relocations are counted into the thunk pool.
            if (from_section == .Code) {
                if (maybe_unique_data) |unique| {
                    const got = module.get_got();
                    if (unique.find_thunk(thunk_index, @intFromPtr(got.ptr), address_from)) |thunk_address| {
                        target.* = thunk_address;
                        continue;
                    }
                }
            }

            target.* = address_from;
        }
    }

    fn process_copy_relocations(self: Loader, parser: *const Parser, module: *Module) !void {
        const bss = module.get_bss();
        for (parser.copy_relocations.relocations) |rel| {
            const maybe_symbol = parser.imported_symbols.element_at(rel.symbol_index);
            if (maybe_symbol) |symbol| {
                const name = symbol.name();
                const maybe_entry = self.find_symbol(module, name);
                if (maybe_entry) |entry| {
                    const src: [*]const u8 = @ptrFromInt(entry.address);
                    const dst: [*]u8 = @ptrFromInt(@intFromPtr(bss.ptr) + rel.bss_offset);
                    @memcpy(dst[0..rel.size], src[0..rel.size]);
                    log.debug("R_ARM_COPY: '{s}' {d} bytes from 0x{x} to BSS+0x{x}", .{ name, rel.size, entry.address, rel.bss_offset });
                } else {
                    log.err("[yasld] R_ARM_COPY: can't find symbol '{s}'", .{name});
                    return LoaderError.SymbolNotFound;
                }
            } else {
                log.err("[yasld] R_ARM_COPY: can't find imported symbol at index {d}", .{rel.symbol_index});
                return LoaderError.SymbolNotFound;
            }
        }
    }

    /// Validate the image before anything else in it is trusted: it is a file
    /// off a filesystem, possibly built by another toolchain for another part,
    /// and running code compiled for hardware this CPU does not have fails as
    /// a fault (or, for a wrong ABI, as silently wrong results).
    fn process_header(self: Loader, module_address: *const anyopaque) ImageError!*const Header {
        const header: *const Header = @ptrCast(@alignCast(module_address));
        if (!std.mem.eql(u8, std.mem.asBytes(&header.magic), "YAFF")) {
            return error.IncorrectSignature;
        }
        if (header.yaff_version != header_module.supported_yaff_version) {
            log.err("YAFF version {d} is not supported (this loader reads v{d}), rebuild the image", .{
                header.yaff_version,
                header_module.supported_yaff_version,
            });
            return error.UnsupportedYaffVersion;
        }

        const image_arch: Architecture = @enumFromInt(header.arch);
        if (image_arch != self.machine.arch) {
            log.err("image is for {s}, this machine is {s}", .{
                image_arch.name(),
                self.machine.arch.name(),
            });
            return error.UnsupportedArchitecture;
        }

        const arch_section = header_module.get_arch_section(header) orelse {
            log.err("image has no architecture section, rebuild the image", .{});
            return error.MissingArchSection;
        };

        const image_abi: FloatAbi = @enumFromInt(arch_section.float_abi);
        if (!image_abi.is_compatible_with(self.machine.float_abi)) {
            log.err("image uses the {s} float ABI, this system is {s}", .{
                image_abi.name(),
                self.machine.float_abi.name(),
            });
            return error.UnsupportedFloatAbi;
        }

        const required = Features.from_bits(arch_section.required_features);
        const missing = required.missing(self.machine.features);
        if (!missing.is_empty()) {
            log.err("image needs {f} (built for fpu '{s}'), this machine provides {f} -- missing {f}", .{
                required,
                (@as(Fpu, @enumFromInt(arch_section.fpu))).name(),
                self.machine.features,
                missing,
            });
            return error.UnsupportedCpuFeatures;
        }

        return header;
    }
};

var loader_object: ?Loader = null;

pub fn init(file_resolver: anytype, allocator: std.mem.Allocator, machine: MachineProfile) void {
    loader_object = Loader.create(file_resolver, allocator, machine);
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
