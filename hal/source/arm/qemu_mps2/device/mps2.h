/*
 * mps2.h
 *
 * Minimal CMSIS device header for the ARM MPS2-AN505 (Cortex-M33 / ARMv8-M)
 * as modelled by QEMU's `mps2-an505` machine. This defines just enough for the
 * generic CMSIS `core_cm33.h` to be included (IRQn_Type + the feature macros).
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation, either version
 * 3 of the License, or (at your option) any later version.
 */

#ifndef YASOS_MPS2_AN505_H
#define YASOS_MPS2_AN505_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum IRQn {
    /* Cortex-M33 processor exceptions */
    NonMaskableInt_IRQn   = -14,
    HardFault_IRQn        = -13,
    MemoryManagement_IRQn = -12,
    BusFault_IRQn         = -11,
    UsageFault_IRQn       = -10,
    SecureFault_IRQn      = -9,
    SVCall_IRQn           = -5,
    DebugMonitor_IRQn     = -4,
    PendSV_IRQn           = -2,
    SysTick_IRQn          = -1,

    /* MPS2-AN505 external interrupts (subset; UART RX/TX used by the HAL). */
    UART0_RX_IRQn         = 47,
    UART0_TX_IRQn         = 48,
    UART1_RX_IRQn         = 49,
    UART1_TX_IRQn         = 50,
} IRQn_Type;

/* ---- Processor and core peripheral configuration ---- */
#define __CM33_REV              0x0000U   /* Core revision r0p0          */
#define __NVIC_PRIO_BITS        3U        /* SSE-200 Cortex-M33: 3 bits  */
#define __Vendor_SysTickConfig  0U        /* Use default SysTick_Config  */
#define __VTOR_PRESENT          1U        /* VTOR present                */
#define __MPU_PRESENT           1U        /* MPU present                 */
#define __SAU_PRESENT           1U        /* SAU present                 */
#define __SAUREGION_PRESENT     1U        /* SAU regions present         */
#define __FPU_PRESENT           1U        /* FPU present                 */
#define __FPU_DP                0U        /* Single precision FPU        */
#define __DSP_PRESENT           0U        /* No DSP extension            */
#define __ICACHE_PRESENT        0U
#define __DCACHE_PRESENT        0U
#define __DTCM_PRESENT          0U

#include "core_cm33.h"

#ifdef __cplusplus
}
#endif

#endif /* YASOS_MPS2_AN505_H */
