//
// header.zig
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
const log = std.log.scoped(.yasld);

const c = @cImport({
    @cInclude("tccyaff.h");
});

pub const Header = c.YaffHeader;

/// Machine requirements of the image, found at Header.arch_section_offset.
pub const ArchSection = c.YaffArchSection;

/// The only on-disk layout this loader understands. An image written by an
/// older or newer toolchain is refused rather than guessed at.
pub const supported_yaff_version: u8 = c.YAFF_VERSION;

/// All of these mirror enums in libs/tinycc/source/obj/tccyaff.h and are deliberately
/// non-exhaustive: the values come from a file that may have been produced by
/// any toolchain, so an unknown one has to be a rejectable value rather than
/// illegal behaviour in @enumFromInt.
pub const Type = enum(u8) {
    Unknown = 0,
    Executable = 1,
    Library = 2,
    _,
};

pub const Architecture = enum(u16) {
    Unknown = 0,
    Armv6_m = 1,
    Armv7_m = 2,
    Armv7e_m = 3,
    Armv8_m = 4,
    _,

    pub fn name(self: Architecture) []const u8 {
        return switch (self) {
            .Unknown => "unknown",
            .Armv6_m => "armv6-m",
            .Armv7_m => "armv7-m",
            .Armv7e_m => "armv7e-m",
            .Armv8_m => "armv8-m",
            _ => "unrecognized",
        };
    }
};

pub const Fpu = enum(u8) {
    None = 0,
    Fpv4_sp_d16 = 1,
    Fpv5_sp_d16 = 2,
    Fpv5_d16 = 3,
    Rp2350 = 4,
    Vfp = 5,
    Vfpv3 = 6,
    Vfpv4 = 7,
    Neon = 8,
    Neon_vfpv4 = 9,
    Neon_fp_armv8 = 10,
    _,

    pub fn name(self: Fpu) []const u8 {
        return switch (self) {
            .None => "none",
            .Fpv4_sp_d16 => "fpv4-sp-d16",
            .Fpv5_sp_d16 => "fpv5-sp-d16",
            .Fpv5_d16 => "fpv5-d16",
            .Rp2350 => "rp2350",
            .Vfp => "vfp",
            .Vfpv3 => "vfpv3",
            .Vfpv4 => "vfpv4",
            .Neon => "neon",
            .Neon_vfpv4 => "neon-vfpv4",
            .Neon_fp_armv8 => "neon-fp-armv8",
            _ => "unrecognized",
        };
    }
};

pub const FloatAbi = enum(u8) {
    /// No FP instructions at all; FP arguments in general purpose registers.
    Soft = 0,
    /// FP instructions allowed; FP arguments still in general purpose registers.
    Softfp = 1,
    /// FP arguments and results in FP registers.
    Hard = 2,
    _,

    pub fn name(self: FloatAbi) []const u8 {
        return switch (self) {
            .Soft => "soft",
            .Softfp => "softfp",
            .Hard => "hard",
            _ => "unrecognized",
        };
    }

    /// soft and softfp pass floating point arguments identically, so code built
    /// either way interoperates; hard float does not mix with either.
    pub fn is_compatible_with(image: FloatAbi, machine: FloatAbi) bool {
        return (image == .Hard) == (machine == .Hard);
    }
};

/// Hardware that has to be present and enabled for an image to run correctly.
/// The image declares what it needs, the kernel declares what the part has.
pub const Features = packed struct(u32) {
    fpu_sp: bool = false,
    fpu_dp: bool = false,
    dcp: bool = false,
    reserved_: u29 = 0,

    pub fn from_bits(value: u32) Features {
        return @bitCast(value);
    }

    pub fn bits(self: Features) u32 {
        return @bitCast(self);
    }

    pub fn is_empty(self: Features) bool {
        return self.bits() == 0;
    }

    /// What `required` asks for that `provided` does not have.
    pub fn missing(required: Features, provided: Features) Features {
        return from_bits(required.bits() & ~provided.bits());
    }

    pub fn format(self: Features, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.is_empty()) {
            return writer.writeAll("none");
        }
        var first = true;
        inline for (.{
            .{ self.fpu_sp, "fpu-sp" },
            .{ self.fpu_dp, "fpu-dp" },
            .{ self.dcp, "dcp" },
        }) |entry| {
            if (entry[0]) {
                if (!first) try writer.writeAll("+");
                try writer.writeAll(entry[1]);
                first = false;
            }
        }
        if (self.reserved_ != 0) {
            if (!first) try writer.writeAll("+");
            try writer.print("unknown(0x{x})", .{self.reserved_});
        }
    }
};

// The numbering above is the on-disk format, so it may not drift from the C
// definitions the writer uses.
comptime {
    std.debug.assert(@intFromEnum(Architecture.Unknown) == c.YAFF_ARCH_UNKNOWN);
    std.debug.assert(@intFromEnum(Architecture.Armv6_m) == c.YAFF_ARCH_ARMV6_M);
    std.debug.assert(@intFromEnum(Architecture.Armv7_m) == c.YAFF_ARCH_ARMV7_M);
    std.debug.assert(@intFromEnum(Architecture.Armv7e_m) == c.YAFF_ARCH_ARMV7E_M);
    std.debug.assert(@intFromEnum(Architecture.Armv8_m) == c.YAFF_ARCH_ARMV8_M);

    std.debug.assert(@intFromEnum(Fpu.None) == c.YAFF_FPU_NONE);
    std.debug.assert(@intFromEnum(Fpu.Fpv5_sp_d16) == c.YAFF_FPU_FPV5_SP_D16);
    std.debug.assert(@intFromEnum(Fpu.Fpv5_d16) == c.YAFF_FPU_FPV5_D16);
    std.debug.assert(@intFromEnum(Fpu.Rp2350) == c.YAFF_FPU_RP2350);

    std.debug.assert(@intFromEnum(FloatAbi.Soft) == c.YAFF_FLOAT_ABI_SOFT);
    std.debug.assert(@intFromEnum(FloatAbi.Softfp) == c.YAFF_FLOAT_ABI_SOFTFP);
    std.debug.assert(@intFromEnum(FloatAbi.Hard) == c.YAFF_FLOAT_ABI_HARD);

    std.debug.assert((Features{ .fpu_sp = true }).bits() == c.YAFF_ARCH_FEATURE_FPU_SP);
    std.debug.assert((Features{ .fpu_dp = true }).bits() == c.YAFF_ARCH_FEATURE_FPU_DP);
    std.debug.assert((Features{ .dcp = true }).bits() == c.YAFF_ARCH_FEATURE_DCP);
}

/// The architecture section, or null when the image carries none (offset 0
/// lands inside the header itself, so it doubles as the absent sentinel).
/// The `size` field is the forward compatibility hinge: a newer writer appends
/// fields and grows it, so a section at least as long as what we read here is
/// usable and anything beyond is ignored.
pub fn get_arch_section(header: *const Header) ?*const ArchSection {
    if (header.arch_section_offset == 0) return null;
    const section: *const ArchSection = @ptrFromInt(@intFromPtr(header) + header.arch_section_offset);
    if (section.size < @sizeOf(ArchSection)) return null;
    return section;
}

// pub const Header = packed struct {
//     marker: u32,
//     module_type: u8,
//     arch: u16,
//     yasiff_version: u8,
//     code_length: u32,
//     init_length: u32,
//     data_length: u32,
//     bss_length: u32,
//     entry: u32,
//     external_libraries_amount: u16,
//     alignment: u8,
//     text_and_data_separation: u8,
//     version_major: u16,
//     version_minor: u16,
//     symbol_table_relocations_amount: u16,
//     local_relocations_amount: u16,
//     data_relocations_amount: u16,
//     reserved2_: u16,
//     exported_symbols_amount: u16,
//     imported_symbols_amount: u16,
//     got_length: u32,
//     got_plt_length: u32,
//     plt_length: u32,
//     arch_section_offset: u16,
//     imported_libraries_offset: u16,
//     relocations_offset: u16,
//     imported_symbols_offset: u16,
//     exported_symbols_offset: u16,
//     text_offset: u16,
//     imported_symbols_lookup_offset: u16,
//     // exported_symbols_lookup_offset: u16,
//     stack_size: u32,  // per-image stack hint; 0xFFFFFFFF = OS default
//     heap_size: u32,   // per-image heap cap;   0xFFFFFFFF = free to grow
//     const_rodata_length: u32, // RELRO shared-const-rodata size; 0 = none
// };

pub fn print_header(header: *const Header) void {
    log.debug("  YAFF header: {{", .{});
    log.debug("    marker: '{s}' (0x{x}),", .{ std.mem.asBytes(&header.magic), header.magic });
    log.debug("    type: {s},", .{switch (@as(Type, @enumFromInt(header.module_type))) {
        .Unknown => "Unknown",
        .Executable => "Executable",
        .Library => "Library",
        _ => "unrecognized",
    }});
    log.debug("    arch: {s},", .{(@as(Architecture, @enumFromInt(header.arch))).name()});
    log.debug("    yaff_version: {d},", .{header.yaff_version});
    log.debug("    code_length: 0x{x},", .{header.code_length});
    log.debug("    init_length: 0x{x},", .{header.init_length});
    log.debug("    data_length: 0x{x},", .{header.data_length});
    log.debug("    bss_length: 0x{x},", .{header.bss_length});
    log.debug("    entry: 0x{x},", .{header.entry});
    log.debug("    external_libraries: 0x{x},", .{header.external_libraries_amount});
    log.debug("    alignment: {d},", .{header.alignment});
    log.debug("    version: {d}.{d},", .{ header.version_major, header.version_minor });
    log.debug("    relocations:", .{});
    log.debug("      symbol_table: {d},", .{header.symbol_table_relocations_amount});
    log.debug("      local: {d},", .{header.local_relocations_amount});
    log.debug("      data: {d},", .{header.data_relocations_amount});
    log.debug("    exported_symbols: {d},", .{header.exported_symbols_amount});
    log.debug("    imported_symbols: {d},", .{header.imported_symbols_amount});
    log.debug("    got_size: {d},", .{header.got_length});
    log.debug("    got_plt_size: {d},", .{header.got_plt_length});
    log.debug("    plt_size: {d},", .{header.plt_length});
    log.debug("    arch_section_offset: {d},", .{header.arch_section_offset});
    if (get_arch_section(header)) |arch| {
        log.debug("    arch_section: {{ fpu: {s}, float_abi: {s}, requires: {f} }},", .{
            (@as(Fpu, @enumFromInt(arch.fpu))).name(),
            (@as(FloatAbi, @enumFromInt(arch.float_abi))).name(),
            Features.from_bits(arch.required_features),
        });
    } else {
        log.debug("    arch_section: none,", .{});
    }
    log.debug("    imported_libraries_offset: {d},", .{header.imported_libraries_offset});
    log.debug("    relocations_offset: {d},", .{header.relocations_offset});
    log.debug("    imported_symbols_offset: {d},", .{header.imported_symbols_offset});
    log.debug("    exported_symbols_offset: {d},", .{header.exported_symbols_offset});
    log.debug("    text_offset: {d},", .{header.text_offset});
    log.debug("    stack_size: 0x{x},", .{header.stack_size});
    log.debug("    heap_size: 0x{x},", .{header.heap_size});
    log.debug("    const_rodata_length: 0x{x},", .{header.const_rodata_length});
    log.debug("  }}", .{});
}

comptime {
    var buf: [30]u8 = undefined;
    if (@sizeOf(Header) != 92) @compileError("Header has incorrect size: " ++ (std.fmt.bufPrint(&buf, "{d}", .{@sizeOf(Header)}) catch "unknown"));
}
