/*
linker_script.ld* Based on https://github.com/ARM-software/CMSIS_5/blob/develop/Device/ARM/ARMCM0plus/Source/GCC/gcc_arm.ld
* and https://github.com/raspberrypi/pico-sdk/blob/master/src/rp2_common/pico_crt0/rp2040/memmap_default.ld
*
* exported symbols:
* __preinit_array_start
* __preinit_array_end
* __init_array_start
* __init_array_end
* __fini_array_start
* __fini_array_end
* __exidx_start
* __exidx_end
*
*
*/

MEMORY
{
  flash(rx!w)       : ORIGIN = 0x10000000, LENGTH = 1024K
  romfs(rx!w)       : ORIGIN = 0x10100000, LENGTH = 4096K
  kernel_ram(rxw)   : ORIGIN = 0x20000000, LENGTH = 76K
  /* Arena for the hybrid /tmp filesystem (source/fs/ramfs, mounted by
   * source/main.zig). Carved out of process_ram so a compile's process image
   * can never eat it; files larger than CONFIG_TMPFS_MAX_FILE_SIZE (or anything
   * that no longer fits here) spill to CONFIG_TMPFS_SPILL_DIRECTORY on the SD
   * card. Kernel-owned: not mapped by the MPU for unprivileged code.
   *
   * 128K -> 32K (2026-08-06). This side of the split was over-provisioned and
   * the other side was the binding constraint: a compile wants ~315 KiB (213
   * heap + 100 image/stack) and could only have 300, so its heap spilled to
   * PSRAM, where the kernel's page clear runs at 55 MB/s against SRAM's 777.
   * Measured /tmp usage after a compile is 3 KiB (MemTmpUsed, /proc/meminfo).
   * The cost is a spill tail: objects are tiny (p99 ~2 KiB) but linked
   * executables are not -- 14 KiB typically, 49 KiB for strlen-5 and 52 KiB for
   * mibench_rijndael -- so those now go to the SD card instead of RAM. Watch
   * MemTmpPeak: if it pins at the ceiling, this went too far. */
  temp_ram(rxw)     : ORIGIN = 0x20013000, LENGTH = 32K
  process_ram(rxw)  : ORIGIN = 0x2001B000, LENGTH = 396K
  /* Kernel MSP stack: 16 KB ending at the top of SRAM (0x20082000). The top
   * 8 KB (0x20080000..0x20082000) is the two 4 KB scratch banks merged (single-
   * core: core1's stack bank is unused) — non-striped SRAM, used first since the
   * stack grows down. The lower 8 KB (0x2007E000..0x20080000) is carved off the
   * top of process_ram and only reached on deep stack usage (e.g. the hardfault
   * handler's diagnostics, which dump a multi-KB maps buffer). kernel_ram is now
   * just .bss + ~64 KB heap. */
  scratch(rxw)      : ORIGIN = 0x2007E000, LENGTH = 16K
}

SECTIONS
{
  .text :
  {
    . = ALIGN(4);
    __vectors_start = .;
    KEEP(*(.vectors))
    __vectors_end = .;
    __bootmeta_start__ = .;
    KEEP(*(.bootmeta))
    __bootmeta_end__ = .;
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

   .romfs :
  {
    /* The rootfs image is flashed SEPARATELY into the romfs flash region (it is
     * not linked into this section, so *(.romfs) is empty). Span the symbols
     * over the whole romfs memory region so the kernel MPU maps it executable —
     * otherwise unprivileged execve'd processes whose XIP .text lives above the
     * 1 MB kernel-flash region fault with IACCVIOL. */
    __romfs_start__ = ORIGIN(romfs);
    KEEP(*(.romfs))
    __romfs_end__ = ORIGIN(romfs) + LENGTH(romfs);
  } > romfs
  /* keep this at beginning of ram or align to arm alignment requirement for
   cortex-m0plus */
  .ram_vector_table (NOLOAD) :
  {
    *(.ram_vector_table)
  } > kernel_ram

  __data_start_flash__ = LOADADDR(.data);
  .data :
  {
    . = ALIGN(4);
    __data_start__ = .;
    *(vtable)
    *(.time_critical*)
    *(.time_critical)
    *(.data)
    *(.data*)
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

  .heap (NOLOAD):
  {
    __end__ = .;
    end = __end__;
    KEEP(*(.heap*))
  } > kernel_ram

  __heap_limit__ = ORIGIN(kernel_ram) + LENGTH(kernel_ram);

  /* Any scratch-bank data + the kernel stack live in the 16 KB scratch
   * region. Stack grows down from the top; MSPLIM is the bottom. */
  .scratch (NOLOAD) :
  {
    *(.scratch_x.* .scratch_y.*)
    . = ALIGN(4);
  } > scratch

  .stack_dummy (NOLOAD):
  {
    KEEP(*(.stack* .stack1*))
  } > scratch

  __stack_top__ = ORIGIN(scratch) + LENGTH(scratch);
  __stack_bottom__ = ORIGIN(scratch);

  __flash_start__ = ORIGIN(flash);
  __flash_end__ = ORIGIN(flash) + LENGTH(flash);
  __kernel_ram_start__ = ORIGIN(kernel_ram);
  __kernel_ram_end__ = ORIGIN(kernel_ram) + LENGTH(kernel_ram);
  __process_ram_start__ = ORIGIN(process_ram);
  __process_ram_end__ = ORIGIN(process_ram) + LENGTH(process_ram);
  __temp_ram_start__ = ORIGIN(temp_ram);
  __temp_ram_end__ = ORIGIN(temp_ram) + LENGTH(temp_ram);

  PROVIDE(__stack = __stack_top__);
  ASSERT(__end__ <= __heap_limit__, "kernel_ram too small: .bss/heap exceed kernel_ram")
}
