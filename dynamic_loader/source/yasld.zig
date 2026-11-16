//
// yasld.zig
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

pub const Loader = @import("loader.zig").Loader;
pub const IntegerHashMap = @import("integer_hash_map.zig").IntegerHashMap;
pub const MachineProfile = @import("loader.zig").MachineProfile;
pub const ImageError = @import("loader.zig").ImageError;
pub const Architecture = @import("header.zig").Architecture;
pub const Header = @import("header.zig").Header;
pub const FloatAbi = @import("header.zig").FloatAbi;
pub const Features = @import("header.zig").Features;
pub const Executable = @import("executable.zig").Executable;
pub const Environment = @import("environment.zig").Environment;
pub const SymbolEntry = @import("module.zig").SymbolEntry;
pub const Module = @import("module.zig").Module;
pub fn set_hot_text_allocator(allocator: @import("std").mem.Allocator) void {
    @import("module.zig").hot_text_allocator = allocator;
}

pub fn set_thunk_allocator_of(of: *const fn (@import("std").mem.Allocator) @import("std").mem.Allocator) void {
    @import("module.zig").thunk_allocator_of = of;
}
pub const get_loader = @import("loader.zig").get_loader;
pub const loader_init = @import("loader.zig").init;
pub const loader_deinit = @import("loader.zig").deinit;
pub const set_load_map_logging = @import("loader.zig").set_load_map_logging;
// Temporary load-phase accounting; see load_profile.zig.
pub const load_profile = @import("load_profile.zig");
pub const template = @import("template.zig");
/// Bytes per function pointer thunk slot, which a precache must agree with.
pub fn thunk_size() usize {
    return @import("module.zig").thunk_code().len;
}

pub const Image = @import("loader.zig").Image;

pub const header_size: usize = @sizeOf(Header);

/// How much of a YAFF file `image_length` needs to see: through debug_length.
pub const image_length_prefix: usize = @offsetOf(Header, "debug_length") + @sizeOf(u32);

/// The bytes of a `file_size`-byte YAFF file the loader uses: everything up to
/// its debug data (header.debug_offset, YAFF_VERSION 6), which only a debugger
/// reads -- it can be several times the size of the image.  `prefix` is the
/// start of the file; a file too short to tell, of another version or with no
/// debug data is image to its end, and the loader judges the rest.
pub fn image_length(prefix: []const u8, file_size: usize) usize {
    const std = @import("std");
    if (prefix.len < image_length_prefix or !std.mem.eql(u8, prefix[0..4], "YAFF") or
        prefix[@offsetOf(Header, "yaff_version")] != @import("header.zig").supported_yaff_version) return file_size;
    const offset = std.mem.readInt(u32, prefix[@offsetOf(Header, "debug_offset")..][0..4], .little);
    if (offset < header_size or offset > file_size) return file_size;
    return offset;
}

/// Whether this image asked to live in slow memory (tcc's -slow-memory). The
/// loader rejects a malformed image later; its flag just has no effect then.
pub fn image_prefers_slow_memory(image: Image) bool {
    const header: *const Header = @ptrCast(@alignCast(image.ptr));
    return header_prefers_slow_memory(header);
}

pub fn header_prefers_slow_memory(header: *const Header) bool {
    return (header.memory_flags & @import("header.zig").memory_flag_slow) != 0;
}
