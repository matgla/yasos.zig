//
// common.s
//
// Copyright (C) 2024 Mateusz Stadnik <matgla@live.com>
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
//

.syntax unified 
.cpu cortex-m0plus
.thumb 

#include "hardware/regs/addressmap.h"
#include "hardware/regs/pads_qspi.h"
#include "hardware/regs/ssi.h"


#define SSI_RX_SAMPLE_DELAY 1

#define SCLK_PAD_CONFIGURATION_DRIVE_8MA_SLEWFAST \
  ((PADS_QSPI_QPIO_QSPI_SCLK_DRIVE_VALUE_8MA << PADS_QSPI_GPIO_QSPI_SCLK_DRIVE_LSB) | \
  PADS_QSPI_GPIO_QSPI_SCLK_SLEWFAST_BITS)

.section .text 
.global _bootloader_stage2_start:
.type _bootloader_stage2_start,%function
.thumb_func 

_bootloader_stage2_start:
  // 0 - when called by bootrom 
  // address - when called by user code 
  push {lr}

  ldr r0, =PADS_QSPI_BASE
  ldr r1, =SCLK_PAD_CONFIGURATION_DRIVE_8MA_SLEWFAST
  str r1, [r0, #PADS_QSPI_GPIO_QSPI_SCLK_OFFSET]
  ldr r1, [r0, #PADS_QSPI_GPIO_QSPI_SD0_OFFSET]
  movs r2, #PADS_QSPI_GPIO_QSPI_SD0_SCHMITT_BITS 
  bics r1, r2 
  str r1, [r0, #PADS_QSPI_GPIO_QSPI_SD0_OFFSET]
  str r1, [r0, #PADS_QSPI_GPIO_QSPI_SD1_OFFSET]
  str r1, [r0, #PADS_QSPI_GPIO_QSPI_SD2_OFFSET]
  str r1, [r0, #PADS_QSPI_GPIO_QSPI_SD3_OFFSET]

_bootloader_stage2_configure_xip:
  ldr r0, =XIP_SSI_BASE
  movs r1, #0 
  str r1, [r0, #SSI_SSIENR_OFFSET]

  movs r1, 
