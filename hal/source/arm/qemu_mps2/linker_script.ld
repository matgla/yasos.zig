/*
 * linker_script.ld for QEMU `mps2-an505` (Cortex-M33 / ARMv8-M)
 *
 * Memory map (verified against `info mtree` on qemu-system-arm 10.2 — the an505
 * model backs these three banks with RAM, 24 MB total):
 *   - ssram-0 at 0x10000000 (4 MB): 1 MB code "flash" (.text/.rodata) + the
 *     3 MB fast user "process_ram" pool. (.text is only ~250 KB, so dedicating
 *     a whole 4 MB bank to it would waste 3.75 MB — the tail is a RAM pool.)
 *   - ssram-1+2 at 0x28000000 (4 MB): the kernel RAM (.data/.bss/.heap).
 *   - Flat 16 MB block ("mps.ram") at 0x80000000 holds the rest:
 *       romfs       (embedded rootfs image, LOADed by `-kernel`)   5 MB
 *       psram       (large "slow" user pool)                       9.75 MB
 *       fatdisk     (host-readable FAT block-device window)        1 MB
 *       kstack      (kernel MSP stack, see below)                  256 K
 *
 * Sizing is driven by the on-device tcc compile tests. A large translation unit
 * needs both a big user "slow" pool AND a big kernel heap (its multi-MB
 * allocations grow the kernel heap via _sbrk — the gcc-torture limits-stringlit
 * 1 MB string literal OOMed a 2 MB kernel_ram). So kernel_ram gets the whole
 * 4 MB ssram-1+2 bank and psram gets 9.75 MB, leaving the romfs a 5 MB window
 * (the image is ~4.3 MB). This is the an505's ceiling: with only 24 MB total and
 * fatdisk+kstack pinned at the top of the 16 MB bank, romfs and the slow pool
 * trade off directly — a roomier romfs would need a bigger board (see the parked
 * mps3-an524 port under hal/source/arm/qemu_mps3, which has 2 GB DDR). The romfs
 * blob is a normal LOADed section, so `qemu-system-arm -kernel` copies it to its
 * VMA (0x80000000); the board's Flash HAL points there so the RomFs mount path
 * is unchanged.
 *
 * kstack stays at the very top of the 16 MB block — ABOVE every process pool —
 * so the vfork register-rescue path (process_vfork_child /
 * process_get_back_to_parent_vfork) temporarily does
 * `mov sp, <rescue block on the kernel stack>`, and ARMv8-M enforces PSPLIM on
 * MOV SP; a kernel stack below a process stack would fault with STKOF (as on the
 * rp2350, the kernel stack is the highest RAM).
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 */

MEMORY
{
  /* ssram-0 (4 MB), split: 1 MB code "flash" + 3 MB fast user pool. */
  flash       (rx!w) : ORIGIN = 0x10000000, LENGTH = 1024K
  /* Fast user process pool — the tail of ssram-0. Backs non-XIP user code. */
  process_ram (rwx)  : ORIGIN = 0x10100000, LENGTH = 3008K
  /* Arena for the hybrid /tmp filesystem (source/fs/ramfs, mounted by
     source/main.zig): carved off the tail of the fast pool so a process image
     can never eat it. Files past CONFIG_TMPFS_MAX_FILE_SIZE spill to
     CONFIG_TMPFS_SPILL_DIRECTORY. Kernel-owned, so the MPU leaves it unmapped. */
  temp_ram    (rw)   : ORIGIN = 0x103F0000, LENGTH = 64K
  /* Kernel .data/.bss/.heap — the whole ssram-1+2 bank. 4 MB so large on-device
     tcc compiles don't exhaust it: a big translation unit (e.g. the gcc-torture
     limits-stringlit 1 MB string literal) grows the kernel heap via _sbrk by
     >1 MB, which OOMed a smaller kernel_ram. */
  kernel_ram  (rwx)  : ORIGIN = 0x28000000, LENGTH = 4096K
  /* Embedded romfs image at the base of the 16 MB block — 5 MB (image is
     ~4.3 MB). Kept small so the slow pool below can be large. LOADed by `-kernel`. */
  romfs       (rw)   : ORIGIN = 0x80000000, LENGTH = 5120K
  /* "Slow" user process pool (memory region[2], the bulk pool every process
     allocates from — see process_memory_pool.zig). 9.75 MB so tcc's user-side
     allocations for big translation units fit. Ends where fatdisk begins. */
  psram       (rw)   : ORIGIN = 0x80500000, LENGTH = 9984K
  /* fatdisk is a 1 MB window backing a host-readable FAT block device (the
     board's `fatdisk0`). Under a host-mmap'd RAM launch
     (`memory-backend-file,share=on`) it maps to a fixed offset in the backing
     file (0x80EC0000 - 0x80000000 = 0x00EC0000) that scripts/* hardcode, so the
     host can drop in test sources and read out device-compiled binaries via
     scripts/fatimg without a kernel rebuild. It is NOT a LOADed section; under a
     plain-RAM launch the window is garbage, the FatFs mount fails and is skipped
     (source/main.zig). Keep it at 0x80EC0000. */
  fatdisk     (rw)   : ORIGIN = 0x80EC0000, LENGTH = 1024K
  kstack      (rw)   : ORIGIN = 0x80FC0000, LENGTH = 256K
}

ENTRY(_start)

__stack_size__ = 256K;

SECTIONS
{
  .text :
  {
    . = ALIGN(4);
    __vectors_start = .;
    KEEP(*(.vectors))
    __vectors_end = .;
    /* .time_critical holds code (irq/syscall fast paths). On the real board it
       runs from RAM; under QEMU there is no benefit, and keeping it in flash
       avoids a >1 GB flash->RAM PREL31 distance in .ARM.exidx. */
    *(.time_critical*)
    *(.time_critical)
    *(.text*)
    KEEP(*(.init))
    KEEP(*(.fini))

    *(.rodata*)
    KEEP(*(.eh_frame*))

    *crtbegin.o(.ctors)
    *crtbegin?.o(.ctors)
    *(EXCLUDE_FILE(*crtend?.o *crtend.o) .ctors)
    *(SORT(.ctors.*))
    *(.ctors)
    *crtbegin.o(.dtors)
    *crtbegin?.o(.dtors)
    *(EXCLUDE_FILE(*crtend?.o *crtend.o) .dtors)
    *(SORT(.dtors.*))
    *(.dtors)

    . = ALIGN(4);
    PROVIDE_HIDDEN(__preinit_array_start = .);
    KEEP(*(SORT(.preinit_array.*)))
    KEEP(*(.preinit_array))
    PROVIDE_HIDDEN(__preinit_array_end = .);

    . = ALIGN(4);
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(SORT(.init_array.*)))
    KEEP(*(.init_array))
    PROVIDE_HIDDEN(__init_array_end = .);

    . = ALIGN(4);
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(SORT(.fini_array.*)))
    KEEP(*(.fini_array))
    PROVIDE_HIDDEN(__fini_array_end = .);
  } > flash

  /* ARM exception handling */
  .ARM.extab :
  {
    *(.ARM.extab* .gnu.linkonce.armextab.*)
  } > flash

  __exidx_start = .;
  .ARM.exidx :
  {
    *(.ARM.exidx* .gnu.linkonce.armexidx.*)
  } > flash
  __exidx_end = .;

  /* Embedded rootfs image (see startup/rootfs.S). LOADed by QEMU -kernel. */
  .romfs :
  {
    . = ALIGN(4);
    __romfs_start__ = .;
    KEEP(*(.romfs))
    __romfs_end__ = .;
  } > romfs

  __data_start_flash__ = LOADADDR(.data);
  .data :
  {
    . = ALIGN(4);
    __data_start__ = .;
    *(vtable)
    *(.data)
    *(.data*)
    . = ALIGN(4);
    __data_end__ = .;
  } > kernel_ram AT> flash

  .bss (NOLOAD) :
  {
    . = ALIGN(4);
    __bss_start__ = .;
    *(.bss)
    *(.bss.*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end__ = .;
  } > kernel_ram

  .heap (NOLOAD) :
  {
    . = ALIGN(8);
    __end__ = .;
    end = __end__;
    __heap_start__ = .;
    KEEP(*(.heap*))
  } > kernel_ram

  /* Kernel MSP stack lives in the dedicated high `kstack` region, ABOVE every
     process pool, so a vfork rescue block on the kernel stack is never below a
     process PSPLIM. The kernel heap then reclaims all of kernel_ram. */
  __stack_top__ = ORIGIN(kstack) + LENGTH(kstack);
  __stack_bottom__ = ORIGIN(kstack);
  __stack = __stack_top__;
  __heap_limit__ = ORIGIN(kernel_ram) + LENGTH(kernel_ram);
  __HeapLimit = __heap_limit__;

  __flash_start__ = ORIGIN(flash);
  __flash_end__ = ORIGIN(flash) + LENGTH(flash);
  __kernel_ram_start__ = ORIGIN(kernel_ram);
  __kernel_ram_end__ = ORIGIN(kernel_ram) + LENGTH(kernel_ram);
  __process_ram_start__ = ORIGIN(process_ram);
  __process_ram_end__ = ORIGIN(process_ram) + LENGTH(process_ram);
  __temp_ram_start__ = ORIGIN(temp_ram);
  __temp_ram_end__ = ORIGIN(temp_ram) + LENGTH(temp_ram);
  __psram_start__ = ORIGIN(psram);
  __psram_end__ = ORIGIN(psram) + LENGTH(psram);

  ASSERT(__heap_start__ <= __heap_limit__, "kernel_ram overflowed (heap into stack)")
}
