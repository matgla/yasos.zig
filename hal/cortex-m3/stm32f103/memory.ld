MEMORY 
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 128K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 20K
}

ENTRY(_init);

__reset_stack_pointer = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS {
    .text : {
        LONG(__reset_stack_pointer);
        LONG(_init | 1);
        /* The whole interrupt table is 332 bytes long. Advance to that position. */
        . += 332;
        /* And here comes the rest of the code, ie. all symbols starting with .text */
        *(.text)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH  /* Put this in the flash memory region */
.ARM.exidx : {
        *(.ARM.exidx*)
        . = ALIGN(4);
    } > FLASH
}
