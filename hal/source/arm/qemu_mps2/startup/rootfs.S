//
// rootfs.S
//
// Embeds the prebuilt rootfs (romfs) image into the kernel ELF. The linker
// script places this `.romfs` section at 0x80800000; QEMU's `-kernel` loader
// copies it there, and the board's Flash HAL points at that address so the
// kernel mounts it exactly as it would the on-flash image on real hardware.
//
// `rootfs.img` is resolved via the assembler include path (-I <repo root>),
// added in build.zig. Rebuild it with ./build_rootfs.sh && ./build_image.sh
// before building the kernel.
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//

.section .romfs, "a"
.align 4
.global __romfs_blob_start
__romfs_blob_start:
.incbin "rootfs.img"
.global __romfs_blob_end
__romfs_blob_end:
