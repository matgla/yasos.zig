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

/* TODO make this configurable via kconfig */
MEMORY 
{
  flash(rx!w)     : ORIGIN = 0x10000000, LENGTH = 512K 
  romfs(rx!w)     : ORIGIN = 0x10080000, LENGTH = 1536K
  ram(rxw)        : ORIGIN = 0x20000000, LENGTH = 256K
  scratch_x(rxw)  : ORIGIN = 0x20040000, LENGTH = 4K 
  scratch_y(rxw)  : ORIGIN = 0x20041000, LENGTH = 4K
}

SECTIONS
{
  .boot2 : 
  {
    __boot2_start__ = .;
    KEEP(*(.boot2))
    __boot2_end__ = .;
  } > flash 

  ASSERT(__boot2_end__ - __boot2_start__ == 256, 
     "Pico second stage bootloader must be 256 bytes in size") 

  .text : 
  {
    . = ALIGN(4);
    KEEP(*(.vectors))
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
    __romfs_start__ = .;
    KEEP(*(.romfs))
    __romfs_end__ = .;
  } > romfs
 
  /* keep this at beginning of ram or align to arm alignment requirement for 
   cortex-m0plus */
  .ram_vector_table (NOLOAD) : 
  {
    *(.ram_vector_table)
  } > ram 

  __data_start_flash__ = LOADADDR(.data);
  .data : 
  {
    . = ALIGN(4);
    __data_start__ = .;
    *(vtable)
    *(.time_critical*)
    *(.data)
    *(.data*)
    . = ALIGN(4);
    __data_end__ = .;
  } > ram AT> flash 

  .bss (NOLOAD) : 
  {
    . = ALIGN(4);
    __bss_start__ = .;
    *(.bss)
    *(.bss.*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end__ = .;
  } > ram 

  .heap (NOLOAD):
  {
    __end__ = .;
    end = __end__;
    KEEP(*(.heap*))
  } > ram 

  __heap_limit__ = ORIGIN(ram) + LENGTH(ram);
    
  .scratch_x : 
  {
    __scratch_x_start__ = .;
    *(.scratch_x.*)
    . = ALIGN(4);
    __scratch_x_end__ = .;
  } > scratch_x AT > flash
  __scratch_x_source__ = LOADADDR(.scratch_x);

  .scratch_y : 
  {
    __scratch_y_start__ = .;
    *(.scratch_y.*)
    . = ALIGN(4);
    __scratch_y_end__ = .;
  } > scratch_y AT > flash 
  __scratch_y_source__ = LOADADDR(.scratch_y);

  .stack1_dummy (NOLOAD):
  {
    *(.stack1*)
  } > scratch_x

  .stack_dummy (NOLOAD):
  {
    KEEP(*(.stack*))
  } > scratch_y 

  __stack_limit__ = ORIGIN(ram) + LENGTH(ram);
  __stack1_top__ = ORIGIN(scratch_x) + LENGTH(scratch_x);
  __stack_top__ = ORIGIN(scratch_y) + LENGTH(scratch_y);
  __stack1_bottom__ = __stack1_top__ - SIZEOF(.stack1_dummy);
  PROVIDE(__stack = __stack_top__); 
  ASSERT(__stack_limit__ >= __heap_limit__, "region RAM overflowed")
}
