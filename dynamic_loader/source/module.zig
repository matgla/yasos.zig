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
// The copy runs and the zeroed thunk tail a relocated-image load starts with.
const template = @import("template.zig");

const get_loader = @import("loader.zig").get_loader;

const log = std.log.scoped(.@"yasld/module");

pub const GotEntry = extern struct {
    symbol_offset: usize,
    base_register: usize,
};

pub const SymbolEntry = struct {
    target_got_address: usize,
    address: usize,
    /// Which module resolved it: 0 the module asked, k + 1 its k-th direct
    /// dependency. With `in_region`, what a relocated-image template needs to
    /// know which base the two addresses move with (template.zig).
    owner: u8 = 0,
    /// `address` is in the owner's per-process region rather than its image.
    in_region: bool = false,
};

/// An exported symbol's runtime address, and whether it lives in the
/// per-process region (data/bss) rather than the image (code, shared rodata).
pub const LocalSymbol = struct {
    address: usize,
    in_region: bool,
};

extern const indirect_call_thunk_template_size: usize;
extern fn indirect_call_thunk_template_start() void;
/// Where the template keeps the callee's GOT base and address (indirect_call_thunk.S).
pub const thunk_r9_offset = template.thunk_r9_offset;
pub const thunk_fn_offset = template.thunk_fn_offset;
pub const thunk_size = template.thunk_size;

/// One thunk slot as the template lays it out: code, then {r9, fn}.
pub fn thunk_code() *const [thunk_size]u8 {
    // Keep this check in ReleaseFast too: replay and allocation rely on the
    // fixed layout, rather than an arbitrary runtime assembly data symbol.
    if (indirect_call_thunk_template_size != thunk_size) @panic("indirect call thunk layout mismatch");
    const start: [*]const u8 = @ptrFromInt(@intFromPtr(&indirect_call_thunk_template_start) & ~@as(usize, 1));
    return start[0..thunk_size];
}

/// No reference count, deliberately. The block comes from the process pool,
/// whose tier 1 is PSRAM, and an exclusive store there never succeeds (see
/// source/kernel/sync/placement.zig): the `@atomicRmw` a count's release needs
/// spun forever in `delete` once the block spilled out of SRAM, hanging the
/// exiting process with its parent still waiting on it. Every holder is the one
/// `LoadedUniqueData` that created it, so there is nothing to count.
pub const ThunkHolderData = struct {
    data: []u8,
    generated: bool,

    pub fn create(allocator: std.mem.Allocator, size: usize, zero_from_slot: usize) !*ThunkHolderData {
        // One allocation: [ThunkHolderData header][thunk data]. The process
        // pool is page-granular, so a separate header struct would burn a whole
        // 4 KiB page for ~16 bytes. The header lives at the block head; the
        // thunk bytes (which the process executes) follow in the same RWX page.
        const hdr = @sizeOf(ThunkHolderData);
        const block = try allocator.alloc(u8, hdr + size * thunk_size);
        const self: *ThunkHolderData = @ptrCast(@alignCast(block.ptr));
        self.* = .{
            .data = block[hdr..],
            .generated = false,
        };
        // Zeroed so that a slot which never gets generated reads back as an
        // all-zero {r9, fn} descriptor. Each relocation phase reserves a range,
        // and unresolved weak references or reuse can leave interior holes
        // -- and find_thunk() must not match one, nor may a stray branch land in
        // one and execute whatever the allocator last left there. A load from a
        // relocated-image template names the slots it does fill (`zero_from_slot`
        // is past their complete leading prefix). Clear the rest, including later
        // replayed slots and any interior holes.
        const zero_at = @min(zero_from_slot, size) * thunk_size;
        @memset(self.data[zero_at..], 0);
        return self;
    }

    pub fn delete(self: *ThunkHolderData, allocator: std.mem.Allocator) void {
        const hdr = @sizeOf(ThunkHolderData);
        const base: [*]u8 = @ptrCast(self);
        allocator.free(base[0 .. hdr + self.data.len]);
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
    /// [data][bss][got], starting where the image's data alignment puts it;
    /// data, bss and got are views into it.
    region: []u8,
    /// The allocation behind `region`, which may start up to
    /// data_alignment - 1 bytes before it. Only for freeing.
    _underlaying_memory: []align(region_base_alignment) u8,

    /// What the process allocator is asked for. An image asking for no more
    /// (nearly all of them) needs no padding in front of its region.
    const region_base_alignment = 8;

    /// `from_image` false leaves data and GOT for the caller to fill (from a
    /// relocated-image template); bss is cleared either way. `copy_view` says
    /// which words of [data][got] the image still owns; null means all of them.
    pub fn create(allocator: std.mem.Allocator, process_allocator: std.mem.Allocator, header: *const Header, parser: *const Parser, from_image: bool, copy_view: ?template.View) !*LoadedUniqueData {
        const self = try allocator.create(LoadedUniqueData);
        errdefer allocator.destroy(self);
        // RELRO: the first const_rodata_length bytes of the data region are
        // pure-const .rodata, shared XIP (borrowed by LoadedSharedData) — they
        // are NOT allocated or copied per process. The per-process data segment
        // is just [data][bss][got]; DATA relocation offsets are mapped through
        // Module.resolve_data_offset (offset < const_rodata_length => the shared
        // rodata; otherwise => this buffer at offset - const_rodata_length).
        const data_part = header.data_length - header.const_rodata_length;
        // memory is combined just for optimization purposes, they may even fit in single page for small modules
        const _t_alloc = profile.now_us();
        // Each object keeps its link-time alignment only if the region starts
        // at the phase the linker gave it: A % data_alignment ==
        // data_alignment_offset (both checked by Loader.process_header).
        const region_length = data_part + header.bss_length + header.got_length;
        const alignment: usize = header.data_alignment;
        const phase: usize = header.data_alignment_offset;
        const padding: usize = if (alignment <= region_base_alignment) phase else alignment - 1;
        const underlaying_memory = try process_allocator.alignedAlloc(u8, .fromByteUnits(region_base_alignment), padding + region_length);
        profile.account(.process_data_alloc, _t_alloc);
        const _t_copy = profile.now_us();
        defer profile.account(.process_data_copy, _t_copy);
        const skip = (phase -% @intFromPtr(underlaying_memory.ptr)) & (alignment - 1);
        const region = underlaying_memory[skip .. skip + region_length];
        const got_pointer: [*]GotEntry = @ptrFromInt(@intFromPtr(region.ptr) + data_part + header.bss_length);
        self.* = .{
            .data = null,
            .bss = null,
            .got = null,
            .thunks = null,
            .allocator = allocator,
            .process_allocator = process_allocator,
            .region = region,
            ._underlaying_memory = underlaying_memory,
        };
        if (data_part > 0) {
            self.data = region[0..data_part];
        }

        if (header.bss_length > 0) {
            self.bss = region[data_part .. header.bss_length + data_part];
            @memset(self.bss.?, 0);
        }

        if (header.got_length > 0) {
            self.got = got_pointer[0 .. header.got_length / @sizeOf(GotEntry)];
        }

        if (from_image) {
            // The image's own words: every one of them for a plain load, only
            // the runs a template left alone for a replay. Words a store covers
            // are copied too and then overwritten, so the runs are exactly what
            // the copy may skip -- and that is most of a typical image's data,
            // which the old full copy handed over twice.
            const data_bytes = region[0..data_part];
            const got_bytes = region[data_part + header.bss_length ..][0..header.got_length];
            template.copy_from_image(data_bytes, got_bytes, parser.get_process_data(), parser.get_got(), if (copy_view) |view| view.copy_runs else &.{}, if (copy_view) |view| view.copy_all else true);
        }

        return self;
    }

    /// `zero_from_slot` is past the slots a relocated-image template fills:
    /// clear the remainder, including interior holes between later replayed slots.
    /// Zero for any other load.
    pub fn allocate_thunks(self: *LoadedUniqueData, size: usize, zero_from_slot: usize) !void {
        if (self.thunks == null) {
            self.thunks = try ThunkHolderData.create(self.process_allocator, size, zero_from_slot);
        }
    }

    pub fn generate_thunk(self: *LoadedUniqueData, index: usize, r9: usize, symbol: usize) !usize {
        if (self.thunks) |thunks| {
            const position = index * thunk_size;
            if (position + thunk_size > thunks.data.len) {
                return error.IndexOutOfBounds;
            }
            @memcpy(thunks.data[position..][0..thunk_size], thunk_code());
            // Patch the per-slot {r9, fn} descriptor the template's two literal
            // loads read, at +8/+12 (indirect_call_thunk.S).
            @memcpy(thunks.data[position + thunk_r9_offset .. position + thunk_r9_offset + @sizeOf(usize)], std.mem.asBytes(&r9));
            @memcpy(thunks.data[position + thunk_fn_offset .. position + thunk_fn_offset + @sizeOf(usize)], std.mem.asBytes(&symbol));
            return @intFromPtr(&thunks.data[position]) | 1;
        }
        return error.ThunksNotAllocated;
    }

    /// Find an already-built thunk for `symbol`, or null when there is none.
    ///
    /// C requires every pointer to the same function to compare equal, and a
    /// function reached both through the GOT and through a data initializer
    /// went through two different relocation passes: the GOT entry was given a
    /// thunk, the initializer got the raw code address, and the two compared
    /// unequal (gcc-torture 930608-1: `p = &f; if (p != a[0]) abort();`).
    ///
    /// The {r9, fn} descriptor each slot embeds at +8/+12 is itself the key,
    /// so the slots already written can be searched with no side table.
    /// `count` is how many slots the caller has filled so far — slots past it
    /// hold stale or uninitialised bytes.
    pub fn find_thunk(self: *LoadedUniqueData, count: usize, r9: usize, symbol: usize) ?usize {
        if (self.thunks) |thunks| {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const position = i * thunk_size;
                if (position + thunk_size > thunks.data.len) {
                    break;
                }
                var slot_r9: usize = 0;
                var slot_fn: usize = 0;
                @memcpy(std.mem.asBytes(&slot_r9), thunks.data[position + thunk_r9_offset .. position + thunk_r9_offset + @sizeOf(usize)]);
                @memcpy(std.mem.asBytes(&slot_fn), thunks.data[position + thunk_fn_offset .. position + thunk_fn_offset + @sizeOf(usize)]);
                if (slot_r9 == r9 and slot_fn == symbol) {
                    return @intFromPtr(&thunks.data[position]) | 1;
                }
            }
        }
        return null;
    }

    pub fn get_thunk_address(self: *LoadedUniqueData, index: usize) !usize {
        if (self.thunks) |thunks| {
            const position = index * thunk_size;
            if (position + thunk_size > thunks.data.len) {
                return error.IndexOutOfBounds;
            }
            return @intFromPtr(&thunks.data[position]) | 1;
        }
        return error.ThunksNotAllocated;
    }

    pub fn destroy(self: *LoadedUniqueData) void {
        // Free the regular thunks too — this was previously omitted (relying on
        // bulk process-pool teardown), which leaks on a library unload that does
        // not tear the pool down. This is their only holder (retain_thunks is
        // gone), so delete frees immediately.
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
    /// Address of the image `shared_data` was taken from: the loader's key
    /// for sharing it (see `Loader.modules_list`). Zero until loaded.
    image: usize = 0,
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
    // YAFF_ARCH_FLAG_EXACT_THUMB: the image's code addresses (exported
    // symbols, data relocation values) already carry their Thumb bit, clear
    // for a data object in an executable section -- trust it as written.
    exact_thumb: bool = false,

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
            .exact_thumb = false,
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
            return @intFromPtr(unique.region.ptr) + (offset - self.const_rodata_length);
        }
        return 0;
    }

    /// Whether `address_in_section(section, offset)` lands in this module's
    /// per-process region (data, bss) rather than its image (code, init, the
    /// shared rodata). Mirrors `resolve_data_offset`.
    pub fn section_in_region(self: Module, section: Section, offset: usize) bool {
        return switch (section) {
            .Data => !self.in_shared_rodata(offset),
            .Bss => true,
            else => false,
        };
    }

    fn in_shared_rodata(self: Module, offset: usize) bool {
        if (self.const_rodata_length == 0 or offset >= self.const_rodata_length) return false;
        const shared = self.shared_data orelse return false;
        return shared.rodata != null;
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

    pub fn find_local_symbol(self: Module, name: []const u8) ?LocalSymbol {
        if (self.shared_data) |shared_data| {
            const maybe_symbol = shared_data.exported_symbols.element_by_name(name);
            if (maybe_symbol) |symbol| {
                const section: Section = @fromBackingInt(@intCast(symbol.section));
                // RELRO-aware: an exported pure-const symbol in .rodata (DATA
                // offset < const_rodata_length) resolves to the shared XIP rodata
                // so cross-module importers see the one shared copy.
                var address = self.address_in_section(section, symbol.offset) catch return null;
                // Cortex-M only supports Thumb mode. Code addresses used with
                // BX/BLX must have bit 0 set to stay in Thumb state; an even
                // address causes an INVSTATE HardFault.
                if ((section == .Code or section == .Init) and !self.exact_thumb and (address & 1 == 0)) {
                    address |= 1;
                }
                return .{ .address = address, .in_region = self.section_in_region(section, symbol.offset) };
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
                        .address = symbol.address,
                        .target_got_address = @intFromPtr(got.ptr),
                        .owner = 0,
                        .in_region = symbol.in_region,
                    };
                }
            }
        }

        var it = self.children.first;
        var owner: u8 = 1;
        while (it) |child_node| : ({
            it = child_node.next;
            owner +%= 1;
        }) {
            const module: *const Module = @fieldParentPtr("child_list_node", child_node);
            const maybe_child_symbol = module.find_local_symbol(name);
            if (module.unique_data) |*data| {
                if (data.*.got) |*got| {
                    if (maybe_child_symbol) |symbol| {
                        return .{
                            .address = symbol.address,
                            .target_got_address = @intFromPtr(got.ptr),
                            .owner = owner,
                            .in_region = symbol.in_region,
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
