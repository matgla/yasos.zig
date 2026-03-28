/*
 * RP2350 overclock — RAM-resident low-level primitives API
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 */
#ifndef OVERCLOCK_H
#define OVERCLOCK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Set VREG voltage via POWMAN direct writes (bypasses SDK 1.3V clamp).
 * vreg_code: e.g. 0x0f0 for 1.3V, 0x120 for 1.5V, 0x170 for 1.9V. */
void overclock_set_voltage(uint32_t vreg_code);

/* Busy-loop delay: ~2 cycles per count (subs+bne). */
void overclock_delay_cycles(uint32_t count);

/* Enable QE bit in W25Q128JV flash Status Register 2 for QSPI.
 * Returns: 0=already set, 1=just enabled, -1=verify failed. */
int overclock_flash_enable_qe(void);

/* Atomically switch PLL + QMI timing/format from RAM.
 * All args must be precomputed before calling. */
void overclock_apply(
    uint32_t vco_freq, uint32_t post_div1, uint32_t post_div2,
    uint32_t qmi_timing, uint32_t qmi_rfmt, uint32_t qmi_rcmd);

#ifdef __cplusplus
}
#endif

#endif /* OVERCLOCK_H */
