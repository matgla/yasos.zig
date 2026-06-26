/*
 * linker_script.ld for QEMU `mps2-an505` (Cortex-M33 / ARMv8-M)
 *
 * Memory map (verified against `info mtree` on qemu-system-arm 10.2 — the an505
 * model backs these three banks with RAM):
 *   - ssram-0 at 0x10000000 (4 MB) holds .text/.rodata (the "flash").
 *   - ssram-1+2 at 0x28000000 (4 MB) is the fast user "process_ram" pool.
 *   - Flat 16 MB block ("mps.ram") at 0x80000000 holds everything else:
 *       romfs       (embedded rootfs image, LOADed by `-kernel`)
 *       kernel_ram  (.data/.bss/.heap/.stack)
 *       psram       (large "slow" user process pool)
 *       fatdisk     (host-readable FAT block-device window)
 *       kstack      (kernel MSP stack, see below)
 *
 * The embedded romfs outgrew the 4 MB ssram-1+2 bank (toybox/zork/... were
 * added), and that bank is the edge of backed RAM so it cannot be enlarged. The
 * romfs therefore moved to the base of the 16 MB block where it has room to
 * grow, and the freed ssram-1+2 bank became the fast process_ram pool. The
 * romfs blob is a normal LOADed section, so `qemu-system-arm -kernel` copies it
 * to its VMA (0x80000000); the board's Flash HAL points there so the kernel's
 * RomFs mount path is unchanged.
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
  flash       (rx!w) : ORIGIN = 0x10000000, LENGTH = 4096K
  /* Fast user process pool — the freed ssram-1+2 bank. Backs the /tmp RamFs
     (see tmp_filesystem_allocator in source/main.zig) and non-XIP user code. */
  process_ram (rwx)  : ORIGIN = 0x28000000, LENGTH = 4096K
  /* Embedded romfs image at the base of the 16 MB block. 6 MB leaves headroom
     over the current ~4.3 MB image for more apps. LOADed by `-kernel`. */
  romfs       (rw)   : ORIGIN = 0x80000000, LENGTH = 6144K
  kernel_ram  (rwx)  : ORIGIN = 0x80600000, LENGTH = 2048K
  /* psram is the large "slow" user process pool (memory region[2] — the pool
     every process actually allocates from, see process_memory_pool.zig). It
     ends exactly where the fatdisk window begins, and sits BELOW kstack so the
     kernel MSP stack stays ABOVE every process PSPLIM (see header comment). */
  psram       (rw)   : ORIGIN = 0x80800000, LENGTH = 6912K
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
  __psram_start__ = ORIGIN(psram);
  __psram_end__ = ORIGIN(psram) + LENGTH(psram);

  ASSERT(__heap_start__ <= __heap_limit__, "kernel_ram overflowed (heap into stack)")
}
