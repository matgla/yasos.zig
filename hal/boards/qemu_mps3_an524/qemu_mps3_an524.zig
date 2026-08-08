//
// qemu_mps2_an505.zig
//
// Board definition for QEMU's `mps2-an505` machine (Cortex-M33 / ARMv8-M).
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

pub const hal = @import("hal");

pub const uart = struct {
    // CMSDK APB UART0 — wired to QEMU's serial console (stdio).
    pub const uart0 = hal.uart.Uart(0, .{}, hal.internal.Uart).create();
};

pub const flash = struct {
    // The romfs image is embedded into the ELF and loaded to the base of DDR at
    // 0x60000000 (see hal/source/arm/qemu_mps3/startup/rootfs.S + linker_script.ld).
    // The MPS3 an524 backs a 2 GB DDR region, so the romfs gets a roomy 64 MB
    // window with no contention against the user pools or kernel heap. The Flash
    // HAL memory-maps it; with romfs_offset = 0 the RomFs reads from the base.
    pub const flash0 = hal.flash.Flash(hal.internal.Flash(0x60000000, 64 * 1024 * 1024)).create(0);

    // Writable, host-readable FAT block device. Backed by the 16 MB `fatdisk`
    // window above the PSRAM pool (see linker_script.ld). Under a host-mmap'd
    // RAM launch (memory-backend-file) this maps to file offset 0x10000000
    // (0x70000000 - 0x60000000), letting the host drop in test sources and read
    // out device-compiled binaries (scripts/fatimg + scripts/qemu_fatdisk_run.py)
    // with no kernel rebuild. main.zig mounts a FatFs on it at /mnt; on a
    // plain-RAM launch the window is garbage so the mount fails and is skipped.
    pub const fatdisk0 = hal.flash.Flash(hal.internal.RamFlash(fatdisk_address, fatdisk_size)).create(0);
};

// Offset of the romfs image within flash0. On the rp2350 board the rootfs lives
// 1 MB into flash; here the embedded blob starts at the mapping base.
pub const romfs_offset: usize = 0;

// FAT block-device window — MUST match the `fatdisk` region in linker_script.ld.
pub const fatdisk_address: usize = 0x70000000;
pub const fatdisk_size: usize = 16 * 1024 * 1024;
