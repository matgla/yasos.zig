    .syntax unified
    .cpu cortex-m33
    .thumb

    .section .isr_vector,"a",%progbits
    .long   __stack
    .long   Reset_Handler
    .rept 62
    .long   Default_Handler
    .endr

    .text
    .thumb_func
    .global Reset_Handler
Reset_Handler:
    ldr     r0, =__stack
    mov     sp, r0
    /* copy .data */
    ldr     r1, =__data_load__
    ldr     r2, =__data_start__
    ldr     r3, =__data_end__
1:  cmp     r2, r3
    bge     2f
    ldr     r0, [r1], #4
    str     r0, [r2], #4
    b       1b
2:  /* zero .bss */
    ldr     r2, =__bss_start__
    ldr     r3, =__bss_end__
    movs    r0, #0
3:  cmp     r2, r3
    bge     4f
    str     r0, [r2], #4
    b       3b
4:  bl      main
    /* semihosting SYS_EXIT */
    movs    r0, #0x18
    ldr     r1, =0x20026
    bkpt    0xab
5:  b       5b

    .thumb_func
    .global Default_Handler
Default_Handler:
    b       .
