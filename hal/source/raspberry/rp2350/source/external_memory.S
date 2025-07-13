/*
 Copyright (c) 2025 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

.syntax unified
.arch armv7-m
.cpu cortex-m33
.thumb 

#include "hardware/regs/addressmap.h"
#include "hardware/regs/qmi.h"
#include "hardware/regs/pads_qspi.h"
#include "hardware/regs/xip.h"


#define PSRAM_CMD_QUAD_EXIT 0xF5
#define PSRAM_CMD_READ_ID 0x9F
#define PSRAM_CMD_QUAD_ENTRY 0x35
#define PSRAM_KNOWN_GOOD_DIE 0x5D
#define PSRAM_CMD_RESET_ENABLE 0x66
#define PSRAM_CMD_RESET 0x99
#define PSRAM_CMD_WRAP_BURST 0xC0
.section .time_critical, "ax"
.align 2

.global qmi_initialize_m1 
.type qmi_initialize_m1, %function
.thumb_func 
qmi_initialize_m1:
    push {r1, r2, r3, lr}
    cpsid i 
qmi_initialize_direct_access:    
    mov r1, #30
    lsl r1, r1, #QMI_DIRECT_CSR_CLKDIV_LSB
    orr r1, r1, #1
    ldr r0, =XIP_QMI_BASE
    str r1, [r0, #QMI_DIRECT_CSR_OFFSET]

    bl qmi_wait_until_busy
    bl qmi_transmit_quad_exit
    bl qmi_read_id
    cmp r2, #0
    beq qmi_disable_direct_access

    bl qmi_entry_quad_mode
    push {r0}
    ldr r3, =XIP_CTRL_BASE
    ldr r1, [r3, 0]
    ldr r0, =XIP_CTRL_WRITABLE_M1_BITS 
    orr r1, r0
    str r1, [r3, 0]  
    pop {r0}


qmi_disable_direct_access:
    ldr r1, [r0, #QMI_DIRECT_CSR_OFFSET]
    ldr r3, =~(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS) 
    and r1, r3
    str r1, [r0, #QMI_DIRECT_CSR_OFFSET]
    mov r0, #0
    cpsie i
    mov r0, r2
    pop {r1, r2, r3, pc}

qmi_wait_until_busy:
    ldr r1, [r0, #QMI_DIRECT_CSR_OFFSET]
    tst r1, #QMI_DIRECT_CSR_BUSY_BITS 
    bne qmi_wait_until_busy
    mov pc, lr

qmi_enable_m1:
    ldr r1, [r0, #QMI_DIRECT_CSR_OFFSET]
    ldr r3, =QMI_DIRECT_CSR_ASSERT_CS1N_BITS
    orr r1, r3
    str r1, [r0, #QMI_DIRECT_CSR_OFFSET]
    mov pc, lr

qmi_disable_m1:
    ldr r1, [r0, #QMI_DIRECT_CSR_OFFSET]
    ldr r3, =~(QMI_DIRECT_CSR_ASSERT_CS1N_BITS) 
    and r1, r3
    str r1, [r0, #QMI_DIRECT_CSR_OFFSET]
    mov pc, lr 

qmi_transmit_quad_exit:
    push {lr} 
    bl qmi_enable_m1
    ldr r1, =(QMI_DIRECT_TX_OE_BITS | QMI_DIRECT_TX_IWIDTH_VALUE_Q << QMI_DIRECT_TX_IWIDTH_LSB | PSRAM_CMD_QUAD_EXIT) 
    str r1, [r0, #QMI_DIRECT_TX_OFFSET]
    bl qmi_wait_until_tx 
    bl qmi_wait_until_busy
    ldr r1, [r0, #QMI_DIRECT_RX_OFFSET]
    bl qmi_disable_m1
    pop {pc}

qmi_wait_until_tx:
    ldr r1, [r0, #QMI_DIRECT_CSR_OFFSET]
    ldr r2, =QMI_DIRECT_CSR_TXEMPTY_BITS
    tst r1, r2
    beq qmi_wait_until_tx
    mov pc, lr

// r1 - data to send
// r2 - data received
qmi_transmit_next:
    push {r1, lr}
    str r1, [r0, #QMI_DIRECT_TX_OFFSET] 
    bl qmi_wait_until_tx
    bl qmi_wait_until_busy
    ldr r2, [r0, #QMI_DIRECT_RX_OFFSET]
    pop {r1, pc}

// r2 - result 
qmi_read_id:
    push {lr}
    bl qmi_enable_m1
    mov r1, #PSRAM_CMD_READ_ID 
    bl qmi_transmit_next
    mov r1, #0xff
    bl qmi_transmit_next
    bl qmi_transmit_next
    bl qmi_transmit_next
    bl qmi_transmit_next
    bl qmi_transmit_next
    mov r3, #PSRAM_KNOWN_GOOD_DIE
    cmp r2, r3 
    bne qmi_read_id_failed 

qmi_read_id_success:
    mov r3, r2
    lsl r3, r3, #8
    bl qmi_transmit_next
    orr r2, r3
    bl qmi_disable_m1
    pop {pc}

qmi_read_id_failed: 
    mov r2, #0 
    bl qmi_disable_m1
    pop {pc}

qmi_delay:
    mov r2, #0 
    cmp r1, #0 
    bne qmi_delay_loop
    mov pc, lr 
qmi_delay_loop:
    add r2, #1
    cmp r2, r1
    bne qmi_delay_loop 
    mov pc, lr

qmi_entry_quad_mode:
    push {r2, lr}
    
    bl qmi_enable_m1
    mov r1, #PSRAM_CMD_RESET_ENABLE
    bl qmi_transmit_next
    bl qmi_disable_m1 
    mov r1, #20
    bl qmi_delay

    bl qmi_enable_m1
    mov r1, #PSRAM_CMD_RESET
    bl qmi_transmit_next
    bl qmi_disable_m1 
    mov r1, #20
    bl qmi_delay

    @ bl qmi_enable_m1
    @ mov r1, #PSRAM_CMD_WRAP_BURST
    @ bl qmi_transmit_next
    @ bl qmi_disable_m1 
    @ mov r1, #20
    @ bl qmi_delay



    bl qmi_enable_m1
    mov r1, #PSRAM_CMD_QUAD_ENTRY
    bl qmi_transmit_next
    bl qmi_disable_m1 
    pop {r2, pc}

.global qmi_dummy_read
.type qmi_dummy_read, %function
.thumb_func
qmi_dummy_read:
    push {r1, r2, r3, lr}
    ldr r1, =1000
    bl qmi_delay 
    ldr r0, =XIP_NOCACHE_NOALLOC_BASE + 0x1000000
    ldrb r0, [r0]
    ldr r1, =1000
    bl qmi_delay 
    
    pop {r1, r2, r3, pc}



// taken from: 
// https://github.com/raspberrypi/pico-sdk/blob/ee68c78d0afae2b69c03ae1a72bf5cc267a2d94c/src/rp2350/boot_stage2/boot2_w25q080.S#L189

#ifndef PICO_FLASH_SPI_CLKDIV
#define PICO_FLASH_SPI_CLKDIV 2
#endif
#if (PICO_FLASH_SPI_CLKDIV << QMI_M0_TIMING_CLKDIV_LSB) & ~QMI_M0_TIMING_CLKDIV_BITS
#error "CLKDIV greater than maximum"
#endif

// RX sampling delay is measured in units of one half clock cycle.

#ifndef PICO_FLASH_SPI_RXDELAY
#define PICO_FLASH_SPI_RXDELAY 2
#endif
#if (PICO_FLASH_SPI_RXDELAY << QMI_M0_TIMING_RXDELAY_LSB) & ~QMI_M0_TIMING_RXDELAY_BITS
#error "RX delay greater than maximum"
#endif


// Define interface width: single/dual/quad IO
#define FRAME_FORMAT SSI_CTRLR0_SPI_FRF_VALUE_QUAD

// For W25Q080 this is the "Read data fast quad IO" instruction:
#define CMD_READ 0xeb
#define MODE_CONTINUOUS_READ 0xa0
#define WAIT_CYCLES 4
#define CMD_WRITE_ENABLE 0x06
#define CMD_READ_STATUS 0x05
#define CMD_READ_STATUS2 0x35
#define CMD_WRITE_STATUS 0x01
#define SREG_DATA 0x02  // Enable quad-SPI mode

#define INIT_M0_RCMD (\
    CMD_READ             << QMI_M0_RCMD_PREFIX_LSB |\
    MODE_CONTINUOUS_READ << QMI_M0_RCMD_SUFFIX_LSB |\
0)

#define INIT_M0_RFMT (\
    QMI_M0_RFMT_PREFIX_WIDTH_VALUE_S << QMI_M0_RFMT_PREFIX_WIDTH_LSB |\
    QMI_M0_RFMT_ADDR_WIDTH_VALUE_Q   << QMI_M0_RFMT_ADDR_WIDTH_LSB |\
    QMI_M0_RFMT_SUFFIX_WIDTH_VALUE_Q << QMI_M0_RFMT_SUFFIX_WIDTH_LSB |\
    QMI_M0_RFMT_DUMMY_WIDTH_VALUE_Q  << QMI_M0_RFMT_DUMMY_WIDTH_LSB |\
    QMI_M0_RFMT_DATA_WIDTH_VALUE_Q   << QMI_M0_RFMT_DATA_WIDTH_LSB |\
    QMI_M0_RFMT_PREFIX_LEN_VALUE_8   << QMI_M0_RFMT_PREFIX_LEN_LSB |\
    QMI_M0_RFMT_SUFFIX_LEN_VALUE_8   << QMI_M0_RFMT_SUFFIX_LEN_LSB |\
    WAIT_CYCLES                      << QMI_M0_RFMT_DUMMY_LEN_LSB |\
0)


// SCLK: 8mA drive, no slew limiting, input buffer disabled
#define INIT_PAD_SCLK  (\
    2 << PADS_QSPI_GPIO_QSPI_SCLK_DRIVE_LSB | \
    PADS_QSPI_GPIO_QSPI_SCLK_SLEWFAST_BITS | \
0)

#define INIT_DIRECT_CSR (\
    30 << QMI_DIRECT_CSR_CLKDIV_LSB | \
    QMI_DIRECT_CSR_EN_BITS | \
    QMI_DIRECT_CSR_AUTO_CS0N_BITS | \
0)

#define INIT_M0_TIMING (\
    1                      << QMI_M0_TIMING_COOLDOWN_LSB |\
    PICO_FLASH_SPI_RXDELAY << QMI_M0_TIMING_RXDELAY_LSB |\
    PICO_FLASH_SPI_CLKDIV  << QMI_M0_TIMING_CLKDIV_LSB |\
0)

.global qmi_reinitialize_flash
.type qmi_reinitialize_flash, %function
.thumb_func
qmi_reinitialize_flash:
    push {lr} 
    ldr r3, =PADS_QSPI_BASE
    movs r0, INIT_PAD_SCLK
    str r0, [r3, #PADS_QSPI_GPIO_QSPI_SCLK_OFFSET]
    adds r3, #REG_ALIAS_CLR_BITS
    movs r0, #PADS_QSPI_GPIO_QSPI_SD0_SCHMITT_BITS
    str r0, [r3, #PADS_QSPI_GPIO_QSPI_SD0_OFFSET]
    str r0, [r3, #PADS_QSPI_GPIO_QSPI_SD1_OFFSET]
    str r0, [r3, #PADS_QSPI_GPIO_QSPI_SD2_OFFSET]
    str r0, [r3, #PADS_QSPI_GPIO_QSPI_SD3_OFFSET]

    adds r3, (XIP_QMI_BASE - (PADS_QSPI_BASE + REG_ALIAS_CLR_BITS))
qmi_program_sreg:
    ldr r1, =INIT_DIRECT_CSR
    str r1, [r3, #QMI_DIRECT_CSR_OFFSET]
1:
    ldr r0, [r3, #QMI_DIRECT_CSR_OFFSET]
    tst r0, #QMI_DIRECT_CSR_BUSY_BITS
    bne 1b

    movs r0, #CMD_READ_STATUS2
    bl read_flash_sreg
    cmp r0, #SREG_DATA
    beq _skip_sreg_programming
    movs r0, #CMD_WRITE_ENABLE
    str r0, [r3, #QMI_DIRECT_TX_OFFSET]
    bl wait_qmi_ready
    ldr r0, [r3, #QMI_DIRECT_RX_OFFSET] 

    movs r0, #CMD_WRITE_STATUS
    str r0, [r3, #QMI_DIRECT_TX_OFFSET]
    movs r0, #0
    str r0, [r3, #QMI_DIRECT_TX_OFFSET]
    movs r0, #SREG_DATA
    str r0, [r3, #QMI_DIRECT_TX_OFFSET]
    bl wait_qmi_ready
    ldr r0, [r3, #QMI_DIRECT_RX_OFFSET]
    ldr r0, [r3, #QMI_DIRECT_RX_OFFSET]
    ldr r0, [r3, #QMI_DIRECT_RX_OFFSET]

1: 
    movs r0, #CMD_READ_STATUS
    bl read_flash_sreg
    lsrs r0, #1
    bcs 1b 

_skip_sreg_programming:
    bics r1, #QMI_DIRECT_CSR_EN_BITS
    str r1, [r3, #QMI_DIRECT_CSR_OFFSET]

_qmi_config:
    ldr r0, =INIT_M0_TIMING
    str r0, [r3, #QMI_M0_TIMING_OFFSET]
    ldr r0, =INIT_M0_RCMD
    str r0, [r3, #QMI_M0_RCMD_OFFSET]
    ldr r0, =INIT_M0_RFMT
    str r0, [r3, #QMI_M0_RFMT_OFFSET]

    mov r1, #XIP_NOCACHE_NOALLOC_BASE
    ldrb r1, [r1]
    
    bic r0, #QMI_M0_RFMT_PREFIX_LEN_BITS 
    str r0, [r3, #QMI_M0_RFMT_OFFSET]

    pop {pc}


read_flash_sreg:
    push {lr} 
    str r0, [r3, #QMI_DIRECT_TX_OFFSET]
    str r0, [r3, #QMI_DIRECT_TX_OFFSET]

    bl wait_qmi_ready
    ldr r0, [r3, #QMI_DIRECT_RX_OFFSET]
    ldr r0, [r3, #QMI_DIRECT_RX_OFFSET]
    pop {pc}

wait_qmi_ready:
1:
    ldr r0, [r3, #QMI_DIRECT_CSR_OFFSET]
    lsrs r0, r0, #QMI_DIRECT_CSR_BUSY_LSB + 1
    bcs 1b
    bx lr