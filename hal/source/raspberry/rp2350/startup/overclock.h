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

/* Calibrate the flash (M0) rxdelay for the current system clock: sweep all
 * eight values, CRC a flash region read uncached at each, and park rxdelay at
 * the centre of the widest timing-valid window. Runs from RAM and flushes the
 * XIP cache. Returns the chosen rxdelay; *out_lo/*out_hi report the passing
 * window [lo..hi]; lo > hi means the sweep was inconclusive and the configured
 * timing was left untouched. Call after the overclock has been applied. */
uint32_t overclock_calibrate_flash_rxdelay(uint32_t *out_lo, uint32_t *out_hi);

/* Price the flash read path at the current QMI configuration, in core cycles
 * per access: a cache-line fill (*out_miss), consecutive uncached words
 * (*out_seq), uncached words 512 B apart (*out_rnd), and the measuring loop
 * itself against a cache hit (*out_ctl), which the other three are net of.
 * Runs from RAM. */
void overclock_flash_probe_read_cost(uint32_t *out_miss, uint32_t *out_seq,
                                     uint32_t *out_rnd, uint32_t *out_ctl);

/* Size the enforced chip-select-high time: cycles per cache-line fill at
 * MIN_DESELECT 0 (*out_cycles_lo) and at the configured value (*out_cycles_hi),
 * which value the configuration holds (*out_configured), and a bitmask of the
 * values that read a flash region back correctly (*out_ok_mask). Restores the
 * timing register before returning — this measures, it does not tune. */
void overclock_flash_probe_deselect(uint32_t *out_cycles_lo, uint32_t *out_cycles_hi,
                                    uint32_t *out_ok_mask, uint32_t *out_configured);

/* Switch the flash to continuous-read mode and drop the 8-bit opcode from every
 * XIP transaction. CRC-verified against the configuration it replaces and
 * reverted on mismatch. Returns 0 if continuous-read is live, -1 if it verified
 * as broken and the previous configuration was restored. Must be called after
 * everything that drives CS0 in QMI direct mode. */
int overclock_flash_enable_continuous_read(void);

#ifdef __cplusplus
}
#endif

#endif /* OVERCLOCK_H */
