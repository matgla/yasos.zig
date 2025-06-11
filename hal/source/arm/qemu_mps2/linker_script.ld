/*
 * linker_script.ld for QEMU `mps2-an505` (Cortex-M33 / ARMv8-M)
 *
 * Memory map (verified against `info mtree` / a gdb RAM-probe on qemu-system-arm
 * 10.2.1 — the an505 model backs these banks with RAM):
 *   - Code SSRAM at 0x10000000 (4 MB) holds .text/.rodata.
 *   - Spare SSRAM-1+2 bank at 0x28000000 (4 MB) holds the embedded romfs image.
 *   - Flat 16 MB PSRAM at 0x80000000 holds everything else, carved into:
 *       kernel_ram  (.data/.bss/.heap/.stack)
 *       process_ram (fast user process pool)
 *       psram       (large "slow" user pool — now ~8 MB)
 *       kstack      (kernel MSP stack, see below)
 *
 * The romfs lives in its own SSRAM bank (rather than eating into the 0x80000000
 * PSRAM) so the whole bottom of the 16 MB block is available to the user pools.
 * Freeing the old 4 MB romfs slot doubles the "psram" pool to ~8 MB. The romfs
 * blob is a normal LOADed section so `qemu-system-arm -kernel` copies it to its
 * VMA (0x28000000); the board's Flash HAL points there so the kernel's RomFs
 * mount path is unchanged.
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 */

MEMORY
{
  flash       (rx!w) : ORIGIN = 0x10000000, LENGTH = 4096K
  /* Spare on-board SSRAM (ssram-1 + ssram-2) — unused by the rest of the
     system, so the romfs blob lives here instead of in the 0x80000000 PSRAM. */
  romfs       (rw)   : ORIGIN = 0x28000000, LENGTH = 4096K
  kernel_ram  (rwx)  : ORIGIN = 0x80000000, LENGTH = 4096K
  /* process_ram backs the /tmp RamFs (see tmp_filesystem_allocator in
     source/main.zig). The 256K kernel MSP stack is carved off its top, so /tmp
     is 4 MB - 256K. */
  process_ram (rwx)  : ORIGIN = 0x80400000, LENGTH = 4096K - 256K
  /* psram is the large user process pool (memory region[2] — the pool every
     process actually allocates from, see process_memory_pool.zig). With romfs
     relocated to its own SSRAM bank, this is now a clean 8 MB. It sits BELOW the
     kstack so the kernel MSP stack stays ABOVE every process PSPLIM: the vfork
     register-rescue path (process_vfork_child / process_get_back_to_parent_vfork)
     temporarily does `mov sp, <rescue block on the kernel stack>`, and ARMv8-M
     enforces PSPLIM on MOV SP, so a kernel stack below a process stack would
     fault with STKOF (as on the rp2350, the kernel stack is the highest RAM). */
  psram       (rw)   : ORIGIN = 0x807C0000, LENGTH = 8192K - 1024K
  /* fatdisk is a 1 MB window backing a host-readable FAT block device (the
     board's `fatdisk0`). It is carved off the TOP of the psram pool so the user
     allocator never touches it. Under a host-mmap'd RAM launch
     (`memory-backend-file,share=on`) it maps to a fixed offset in the backing
     file (0x80EC0000 - 0x80000000 = 0x00EC0000), so the host can drop in test
     sources and read out device-compiled binaries via scripts/fatimg without a
     kernel rebuild. It is NOT a LOADed section; under a plain-RAM launch the
     window is garbage, the FatFs mount fails and is skipped (source/main.zig). */
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

  __kernel_ram_start__ = ORIGIN(kernel_ram);
  __kernel_ram_end__ = ORIGIN(kernel_ram) + LENGTH(kernel_ram);
  __process_ram_start__ = ORIGIN(process_ram);
  __process_ram_end__ = ORIGIN(process_ram) + LENGTH(process_ram);
  __psram_start__ = ORIGIN(psram);
  __psram_end__ = ORIGIN(psram) + LENGTH(psram);

  ASSERT(__heap_start__ <= __heap_limit__, "kernel_ram overflowed (heap into stack)")
}
