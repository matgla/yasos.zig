//
// build.zig
//
// Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

// lwext4 (libs/lwext4), built the way the kernel uses it: ext4 without a
// journal or xattrs, errno and O_ flags from the C library, every allocation
// through ext4_user_malloc (source/fs/ext4/ext4fs.zig), no debug printing.

const std = @import("std");

const lwext4_path = "libs/lwext4/";

/// The configuration, as -D flags for the C sources and as macros for the
/// header translation -- they must agree, or struct layouts differ.
pub const config_macros = [_][2][]const u8{
    .{ "CONFIG_USE_DEFAULT_CFG", "1" },
    .{ "CONFIG_DEBUG_PRINTF", "0" },
    .{ "CONFIG_DEBUG_ASSERT", "0" },
    .{ "CONFIG_JOURNALING_ENABLE", "0" },
    .{ "CONFIG_XATTR_ENABLE", "0" },
    .{ "CONFIG_EXTENTS_ENABLE", "1" },
    .{ "CONFIG_HAVE_OWN_OFLAGS", "0" },
    .{ "CONFIG_HAVE_OWN_ERRNO", "0" },
    .{ "CONFIG_BLOCK_DEV_ENABLE_STATS", "0" },
    // Blocks in each mounted volume's cache: 8 is lwext4's own floor for the
    // operations that hold several blocks at once. 8 KiB a volume at 1 KiB
    // blocks.
    .{ "CONFIG_BLOCK_DEV_CACHE_SIZE", "8" },
    // Blocks nobody references, kept cached across all volumes together (the
    // fork's ext4_bcache.c). Without it every mounted volume holds its last 8
    // blocks for good -- ~27 KiB of kernel heap for the card's three, most of
    // it for volumes nothing is touching. The busy volume can still keep all
    // 8 of its own.
    .{ "CONFIG_BLOCK_DEV_CACHE_IDLE_BUDGET", "8" },
    // Four ext4 volumes at once: the card's three plus one mounted by hand.
    // Each mount point is ~2 KiB of static RAM (it holds the superblock).
    .{ "CONFIG_EXT4_BLOCKDEVS_COUNT", "4" },
    .{ "CONFIG_EXT4_MOUNTPOINTS_COUNT", "4" },
    .{ "CONFIG_EXT4_MAX_BLOCKDEV_NAME", "8" },
    .{ "CONFIG_EXT4_MAX_MP_NAME", "8" },
    .{ "CONFIG_USE_USER_MALLOC", "1" },
};

const sources = [_][]const u8{
    "src/ext4.c",
    "src/ext4_balloc.c",
    "src/ext4_bcache.c",
    "src/ext4_bitmap.c",
    "src/ext4_blockdev.c",
    "src/ext4_block_group.c",
    "src/ext4_crc32.c",
    "src/ext4_debug.c",
    "src/ext4_dir.c",
    "src/ext4_dir_idx.c",
    "src/ext4_extent.c",
    "src/ext4_fs.c",
    "src/ext4_hash.c",
    "src/ext4_ialloc.c",
    "src/ext4_inode.c",
    "src/ext4_journal.c",
    "src/ext4_mbr.c",
    "src/ext4_mkfs.c",
    "src/ext4_super.c",
    "src/ext4_trans.c",
    "src/ext4_xattr.c",
};

pub fn build_lwext4(b: *std.Build, optimize: std.builtin.OptimizeMode, target: std.Build.ResolvedTarget, link_libc: bool) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "lwext4",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = link_libc,
        }),
    });
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-std=gnu11", "-Wno-unused-parameter", "-Werror=implicit-function-declaration", "-ffunction-sections", "-fdata-sections" }) catch @panic("OOM");
    for (config_macros) |macro| {
        flags.append(b.allocator, b.fmt("-D{s}={s}", .{ macro[0], macro[1] })) catch @panic("OOM");
    }
    var files: [sources.len][]const u8 = undefined;
    inline for (sources, 0..) |source, index| files[index] = lwext4_path ++ source;
    lib.root_module.addCSourceFiles(.{ .files = &files, .flags = flags.items });
    lib.root_module.addIncludePath(b.path(lwext4_path ++ "include"));
    return lib;
}

/// ext4.h and friends translated for Zig, with the same configuration.
pub fn headers(b: *std.Build, optimize: std.builtin.OptimizeMode, target: std.Build.ResolvedTarget, link_libc: bool) *std.Build.Step.TranslateC {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("source/fs/ext4/lwext4_c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    translate.addIncludePath(b.path(lwext4_path ++ "include"));
    for (config_macros) |macro| translate.defineCMacro(macro[0], macro[1]);
    return translate;
}
