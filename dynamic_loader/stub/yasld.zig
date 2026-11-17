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

const std = @import("std");
pub const IntegerHashMap = std.AutoHashMap;

pub const Executable = @import("executable.zig").Executable;
pub const Module = @import("module.zig").Module;
const loader = @import("loader.zig");
pub const get_loader = loader.get_loader;
pub const SymbolEntry = @import("module.zig").SymbolEntry;
pub const Loader = loader.Loader;
pub const MachineProfile = loader.MachineProfile;
pub const ImageError = loader.ImageError;
pub const Architecture = loader.Architecture;
pub const FloatAbi = loader.FloatAbi;
pub const Features = loader.Features;

pub fn loader_init(file_resolver: anytype, allocator: std.mem.Allocator, atomics_allocator: std.mem.Allocator, machine: MachineProfile) void {
    loader.init(file_resolver, allocator, atomics_allocator, machine);
}

pub fn loader_deinit() void {
    loader.deinit();
}

pub const set_load_map_logging = loader.set_load_map_logging;

pub const Image = @import("loader.zig").Image;

pub const header_size: usize = 132;

/// The real loader's `image_length` (source/yasld.zig), on the YAFF_VERSION 6
/// layout: debug_offset at 136, the version byte at 7.
pub const image_length_prefix: usize = 144;
pub fn image_length(prefix: []const u8, file_size: usize) usize {
    if (prefix.len < image_length_prefix or !std.mem.eql(u8, prefix[0..4], "YAFF") or prefix[7] != 6) return file_size;
    const offset = std.mem.readInt(u32, prefix[136..][0..4], .little);
    if (offset < image_length_prefix or offset > file_size) return file_size;
    return offset;
}
/// What the kernel reads of a YAFF header without loading the image (the stack hint).
pub const Header = extern struct { magic: u32, _rest: [124]u8, stack_size: u32 };
