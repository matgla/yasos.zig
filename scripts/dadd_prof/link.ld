MEMORY { FLASH(rwx) : ORIGIN = 0x10000000, LENGTH = 512K
         RAM(rwx)   : ORIGIN = 0x80000000, LENGTH = 16M }
ENTRY(Reset_Handler)
SECTIONS {
  .text : { KEEP(*(.isr_vector)) *(.text) *(.text*) *(.rodata) *(.rodata*) } > FLASH
  .data : { __data_start__ = .; *(.data) *(.data*) . = ALIGN(4); __data_end__ = .; } > RAM AT > FLASH
  __data_load__ = LOADADDR(.data);
  .bss (NOLOAD) : { __bss_start__ = .; *(.bss) *(.bss*) *(COMMON) . = ALIGN(4); __bss_end__ = .; } > RAM
  .stack (NOLOAD) : { . = ALIGN(8); . = . + 0x10000; __stack = .; } > RAM
}
