/*
 * linker_script.ld for QEMU `mps3-an524` (Cortex-M33 / ARMv8-M, SSE-200)
 *
 * Chosen over the mps2-an505 because the an505's 24 MB total RAM was too cramped
 * for the on-device tcc compile tests (romfs + user pools + kernel heap all had
 * to share one 16 MB bank, OOMing on large translation units like the gcc-torture
 * limits-stringlit 1 MB string literal). The an524 is the same Cortex-M33/SSE-200
 * family but on the MPS3 board, which backs a 2 GB DDR region — so every region
 * gets tens of MB with no contention.
 *
 * Memory map (verified against `info mtree` + a bare-metal bring-up probe on
 * qemu-system-arm 10.2):
 *   - bram at 0x10000000 (512 KB, the non-secure alias of the SSE code RAM) holds
 *     .text/.rodata (the "flash"). QEMU boots from here exactly like the an505's
 *     0x10000000. .text is ~250 KB, so 512 KB is ample.
 *   - DDR at 0x60000000 (2 GB) holds everything else, sized generously:
 *       romfs       (embedded rootfs image, LOADed by `-kernel`)   64 MB
 *       kernel_ram  (.data/.bss/.heap/.stack)                      32 MB
 *       process_ram (fast user pool)                               32 MB
 *       psram       (large "slow" user pool)                      128 MB
 *       fatdisk     (host-readable FAT block-device window)         1 MB
 *       kstack      (kernel MSP stack)                              1 MB
 *
 * kstack sits ABOVE every process pool so the vfork register-rescue path
 * (`mov sp, <kernel rescue block>`, checked against PSPLIM by ARMv8-M) never sees
 * the kernel stack below a process PSPLIM (same rule as the an505 / rp2350).
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 */

MEMORY
{
  /* SSE code RAM (bram), non-secure alias. Boot/vector table + .text live here. */
  flash       (rx!w) : ORIGIN = 0x10000000, LENGTH = 512K
  /* DDR (2 GB at 0x60000000), carved into generous regions. */
  romfs       (rw)   : ORIGIN = 0x60000000, LENGTH = 64M
  kernel_ram  (rwx)  : ORIGIN = 0x64000000, LENGTH = 32M
  /* Fast user process pool — backs the /tmp RamFs and non-XIP user code. */
  process_ram (rwx)  : ORIGIN = 0x66000000, LENGTH = 32M
  /* "Slow" user process pool (memory region[2], the bulk pool every process
     allocates from — see process_memory_pool.zig). 128 MB: no compile OOMs. */
  psram       (rw)   : ORIGIN = 0x68000000, LENGTH = 128M
  /* fatdisk: 1 MB window for a host-readable FAT block device (board fatdisk0).
     Under a host-mmap'd RAM launch it maps to a fixed file offset that scripts/*
     reference (0x70000000 - 0x60000000 = 0x10000000). NOT a LOADed section; on a
     plain-RAM launch the window is garbage so the FatFs mount fails and is
     skipped (source/main.zig). */
  fatdisk     (rw)   : ORIGIN = 0x70000000, LENGTH = 1M
  /* Kernel MSP stack — highest address, above every process pool (PSPLIM, above). */
  kstack      (rw)   : ORIGIN = 0x70100000, LENGTH = 1M
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
  __psram_start__ = ORIGIN(psram);
  __psram_end__ = ORIGIN(psram) + LENGTH(psram);

  ASSERT(__heap_start__ <= __heap_limit__, "kernel_ram overflowed (heap into stack)")
}
