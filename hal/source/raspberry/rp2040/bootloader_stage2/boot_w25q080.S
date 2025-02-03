//
// second_stage.s
//
// Copyright (C) 2023 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.


// 1. pad config 
// 2. ssi config 
// 3. check flash status register 
// 4. enter XIP 
// 5. configure SSI for XIP 
// 6. jump to 3-stage

#include "hardware/regs/addressmap.h"
#include "hardware/regs/pads_qspi.h"
#include "hardware/regs/ssi.h"
#include "hardware/regs/m0plus.h"

.syntax unified 
.cpu cortex-m0plus
.thumb 

pads_register .req r6 
ssi_register .req r7

// For now hardcoded clk/2, but configuration should be done via menuconfig
#define SSI_CLKDIV 2
#define SSI_RX_SAMPLE_DELAY 1

#define SSI_CONFIGURATION_MODE_CTRLR0 \
  (7 << SSI_CTRLR0_DFS_32_LSB) | \
  (SSI_CTRLR0_TMOD_VALUE_TX_AND_RX << SSI_CTRLR0_TMOD_LSB)

#define SSI_XIP_MODE_CTRLR0 \
  (SSI_CTRLR0_SPI_FRF_VALUE_QUAD << SSI_CTRLR0_SPI_FRF_LSB) | \
  (31 << SSI_CTRLR0_DFS_32_LSB) | \
  (SSI_CTRLR0_TMOD_VALUE_EEPROM_READ << SSI_CTRLR0_TMOD_LSB)

#define SCLK_PAD_CONFIGURATION_DRIVE_8MA_SLEWFAST \
  ((PADS_QSPI_GPIO_QSPI_SCLK_DRIVE_VALUE_8MA << PADS_QSPI_GPIO_QSPI_SCLK_DRIVE_LSB) | \
  PADS_QSPI_GPIO_QSPI_SCLK_SLEWFAST_BITS)


/* W25Q16 commands */
#define FLASH_CMD_READ_STATUS_REGISTER_1 0x05
#define FLASH_CMD_READ_STATUS_REGISTER_2 0x35
#define FLASH_CMD_WRITE_STATUS_REGISTER_2 0x31
#define FLASH_CMD_WRITE_ENABLE 0x06
#define FLASH_CMD_READ_QUAD 0xeb 
#define FLASH_MODE_CONTINOUS_READ 0xa0


#define FLASH_STATUS_REGISTER_2_QE_OFFSET 1 
#define FLASH_STATUS_REGISTER_2_ENABLE_QUAD (1 << FLASH_STATUS_REGISTER_2_QE_OFFSET)
#define FLASH_STATUS_REGISTER_1_BUSY 1

#define FLASH_ADDRESS_LENGTH 8
// can be reduced to 2 ? There are some informations in datasheet
#define FLASH_WAIT_CYCLES 4 

.section .text
.global _start 
.type _start,%function
.thumb_func
_start:
pad_config:
  ldr pads_register, =PADS_QSPI_BASE
  ldr r1, =SCLK_PAD_CONFIGURATION_DRIVE_8MA_SLEWFAST 
  str r1, [pads_register, #PADS_QSPI_GPIO_QSPI_SCLK_OFFSET]
disable_schmitt_on_qspi_pads:
  ldr r1, [pads_register, #PADS_QSPI_GPIO_QSPI_SD0_OFFSET]
  movs r2, #PADS_QSPI_GPIO_QSPI_SD0_SCHMITT_BITS
  bics r1, r2
  str r1, [pads_register, #PADS_QSPI_GPIO_QSPI_SD0_OFFSET]
  str r1, [pads_register, #PADS_QSPI_GPIO_QSPI_SD1_OFFSET]
  str r1, [pads_register, #PADS_QSPI_GPIO_QSPI_SD2_OFFSET]
  str r1, [pads_register, #PADS_QSPI_GPIO_QSPI_SD3_OFFSET]

/* Configure SSI in SPI command form to configure Flash chip for XIP */
configure_ssi_for_configure_flash:
  ldr ssi_register, =XIP_SSI_BASE

  movs r0, #0
  str r0, [ssi_register, #SSI_SSIENR_OFFSET]

  movs r0, #SSI_CLKDIV
  str r0, [ssi_register, #SSI_BAUDR_OFFSET]

  movs r0, #SSI_RX_SAMPLE_DELAY 
  movs r1, #SSI_RX_SAMPLE_DLY_OFFSET 
  str r0, [ssi_register, r1]

  /* store SSI configuration */
  /* 8-bit data transfer mode */
  /* Standard 1-bit SPI frame format */ 
  /* transmit and receive mode */
  ldr r1, =SSI_CONFIGURATION_MODE_CTRLR0
  str r1, [ssi_register, #SSI_CTRLR0_OFFSET]

  /* Let's go */ 
  movs r1, #1 
  str r1, [ssi_register, #SSI_SSIENR_OFFSET]
   

program_flash_chip_configuration:
  /* read status register of W25Q* */ 
  movs r0, #FLASH_CMD_READ_STATUS_REGISTER_2 
  bl transmit_command 
check_if_qe_is_already_enabled: 
  movs r2, #FLASH_STATUS_REGISTER_2_ENABLE_QUAD
  tst r0, r2
  movs r4, r0 
  bne configure_quad_mode

enter_flash_into_continous_read_mode:
  movs r0, #0 
  str r0, [ssi_register, #SSI_SSIENR_OFFSET]
  ldr r1, =(SSI_CTRLR0_SPI_FRF_VALUE_QUAD << SSI_CTRLR0_SPI_FRF_LSB) | \
    (31 << SSI_CTRLR0_DFS_32_LSB) | \
    (SSI_CTRLR0_TMOD_VALUE_EEPROM_READ << SSI_CTRLR0_TMOD_LSB)

  str r1, [ssi_register, #SSI_CTRLR0_OFFSET]

  movs r1, #0 
  str r1, [ssi_register, #SSI_CTRLR1_OFFSET]

/* Setup SPI with SPI command, and quad SPI address */
  ldr r1, =(FLASH_ADDRESS_LENGTH << SSI_SPI_CTRLR0_ADDR_L_LSB) | \
    (FLASH_WAIT_CYCLES << SSI_SPI_CTRLR0_WAIT_CYCLES_LSB) | \
    (SSI_SPI_CTRLR0_INST_L_VALUE_8B << SSI_SPI_CTRLR0_INST_L_LSB) | \
    (SSI_SPI_CTRLR0_TRANS_TYPE_VALUE_1C2A << SSI_SPI_CTRLR0_TRANS_TYPE_LSB)
  ldr r2, =(XIP_SSI_BASE + SSI_SPI_CTRLR0_OFFSET)
  str r1, [r2]

  movs r0, #1 
  str r0, [ssi_register, #SSI_SSIENR_OFFSET]

read_dummy_byte_to_trigger_continous_read_mode:
  movs r0, #FLASH_CMD_READ_QUAD 
  str r0, [ssi_register, #SSI_DR0_OFFSET]
  
  /* 24 bit address (0x000000), mode (0xa), mode ignored (0x0) */
  movs r0, #FLASH_MODE_CONTINOUS_READ
  str r0, [ssi_register, #SSI_DR0_OFFSET]
  
  bl wait_for_transmission_finished

/* Let's remove command prefix, it is harmful in continous reading mode */
reconfigure_ssi_controller_to_remove_command:
  movs r0, #0 
  str r0, [ssi_register, #SSI_SSIENR_OFFSET]

  ldr r0, =(FLASH_MODE_CONTINOUS_READ << SSI_SPI_CTRLR0_XIP_CMD_LSB) | \
    (FLASH_ADDRESS_LENGTH << SSI_SPI_CTRLR0_ADDR_L_LSB) | \
    (FLASH_WAIT_CYCLES << SSI_SPI_CTRLR0_WAIT_CYCLES_LSB) | \
    (SSI_SPI_CTRLR0_INST_L_VALUE_NONE << SSI_SPI_CTRLR0_INST_L_LSB) | \
    (SSI_SPI_CTRLR0_TRANS_TYPE_VALUE_2C2A << SSI_SPI_CTRLR0_TRANS_TYPE_LSB)

  ldr r1, =(XIP_SSI_BASE + SSI_SPI_CTRLR0_OFFSET)
  str r0, [r1]

  movs r1, #1
  str r1, [ssi_register, #SSI_SSIENR_OFFSET]

/* And now flash should be working in memory mapped mode */ 
  ldr r0, =(XIP_BASE + 0x100)
  ldr r1, =(XIP_SSI_BASE + M0PLUS_VTOR_OFFSET)
  str r0, [r1]
  ldmia r0, {r0, r1}
  msr msp, r0
  bx r1 

  /* Software shouldn't exit, but if does go to sleep mode */ 
loop: 
  wfi 
  b loop 

configure_quad_mode:
  movs r0, #FLASH_CMD_WRITE_ENABLE 
  bl write_byte 
  movs r0, r4
  movs r1, #FLASH_STATUS_REGISTER_2_QE_OFFSET
  orrs r0, r1 
  movs r0, #FLASH_CMD_WRITE_STATUS_REGISTER_2  
  bl transmit_command

wait_until_status_register_write_finished:
  movs r0, #FLASH_CMD_READ_STATUS_REGISTER_1
  bl transmit_command
  movs r1, #FLASH_STATUS_REGISTER_1_BUSY
  tst r0, r1 
  bne wait_until_status_register_write_finished
  b enter_flash_into_continous_read_mode 

.global wait_for_transmission_finished 
.type wait_for_transmission_finished,%function 
.thumb_func 
wait_for_transmission_finished: 
  push {r1, r2, lr}

ssi_ready_loop:
  ldr r1, [ssi_register, #SSI_SR_OFFSET]
  movs r2, #SSI_SR_TFE_BITS 
  tst r1, r2
  beq ssi_ready_loop 
  movs r2, #SSI_SR_BUSY_BITS 
  tst r1, r2 
  bne ssi_ready_loop 
  pop {r1, r2, pc}

/* 
  arguments:
    r0 - command to send 
    r1 - payload
  return:
    r0 - received response
*/
.global transmit_command 
.type transmit_command,%function 
.thumb_func
transmit_command: 
  push {lr}
  str r0, [ssi_register, #SSI_DR0_OFFSET]
  // dummy byte, just to trigger next byte transmission 
  str r1, [ssi_register, #SSI_DR0_OFFSET]
 
  bl wait_for_transmission_finished
  ldr r0, [ssi_register, #SSI_DR0_OFFSET] 
  ldr r0, [ssi_register, #SSI_DR0_OFFSET]
  pop {pc}

/* 
  arguments:
    r0 - byte to write 
*/
.global write_byte 
.type write_byte,%function 
.thumb_func
write_byte: 
  push {lr}
  str r0, [ssi_register, #SSI_DR0_OFFSET]
  bl wait_for_transmission_finished 
  /* drop readed byte */
  ldr r0, [ssi_register, #SSI_DR0_OFFSET]
  pop {pc}
