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
  process_ram(rxw)  : ORIGIN = 0x20013000, LENGTH = 436K
  /* The two 4 KB scratch banks merged into one 8 KB region holding the kernel
   * stack (single-core: core1's stack bank is unused). Non-striped SRAM is ideal
   * for the stack. kernel_ram is now just .bss + ~64 KB heap. */
  scratch(rxw)      : ORIGIN = 0x20080000, LENGTH = 8K
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

  /* Any scratch-bank data + the kernel stack live in the merged 8 KB scratch
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

  PROVIDE(__stack = __stack_top__);
  ASSERT(__end__ <= __heap_limit__, "kernel_ram too small: .bss/heap exceed kernel_ram")
}
