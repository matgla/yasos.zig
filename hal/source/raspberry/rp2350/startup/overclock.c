/*
 * RP2350 overclock — RAM-resident low-level primitives
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 *
 * Only functions that must execute from RAM live here:
 *   - POWMAN voltage control (touches flash-mapped VREG)
 *   - QE bit enable via QMI direct mode
 *   - Atomic PLL + QMI switch
 *
 * The high-level init orchestration lives in Zig (crt.zig apply_overclock)
 * where kernel.log is available for debug output.
 */

#include <stdint.h>
#include "hardware/structs/clocks.h"
#include "hardware/structs/qmi.h"
#include "hardware/structs/pll.h"
#include "hardware/regs/clocks.h"
#include "hardware/regs/qmi.h"
#include "hardware/sync.h"
#include "pico/bootrom.h"

/* ---- POWMAN registers (not exposed by SDK) ---- */
#define POWMAN_VREG_CTRL  (*(volatile uint32_t *)0x40100004)
#define POWMAN_VREG       (*(volatile uint32_t *)0x4010000c)
#define POWMAN_BOD        (*(volatile uint32_t *)0x4010001c)
#define POWMAN_PASSWORD   0x5AFE0000u

/* ---- ASM delay (can't use sleep_ms before clocks are configured) ---- */
void __no_inline_not_in_flash_func(overclock_delay_cycles)(uint32_t count) {
    __asm volatile (
        "1: subs %0, %0, #1\n"
        "   bne 1b\n"
        : "+r" (count) :: "cc"
    );
}

/* ---- POWMAN voltage control ---- */
void __no_inline_not_in_flash_func(overclock_set_voltage)(uint32_t vreg_code) {
    /* Lower BOD threshold to avoid reset during voltage transition */
    POWMAN_BOD = POWMAN_PASSWORD | 0x0091u;
    overclock_delay_cycles(100000); /* ~6ms at 12MHz ROSC */

    if (vreg_code > 0x0f0) {
        /* Unlock high-voltage range */
        POWMAN_VREG_CTRL = POWMAN_PASSWORD | 0xA150u;
    }

    POWMAN_VREG = POWMAN_PASSWORD | vreg_code;
    overclock_delay_cycles(250000); /* initial settle */
}

/* ---- QMI Direct Mode helpers (RAM-resident) ---- */

static void __no_inline_not_in_flash_func(qmi_drain_rx)(void) {
    while (!(qmi_hw->direct_csr & QMI_DIRECT_CSR_RXEMPTY_BITS))
        (void)qmi_hw->direct_rx;
}

static uint8_t __no_inline_not_in_flash_func(qmi_direct_xfer)(uint8_t tx) {
    while (qmi_hw->direct_csr & QMI_DIRECT_CSR_TXFULL_BITS)
        ;
    qmi_hw->direct_tx = tx;
    while (qmi_hw->direct_csr & QMI_DIRECT_CSR_RXEMPTY_BITS)
        ;
    return (uint8_t)qmi_hw->direct_rx;
}

static uint8_t __no_inline_not_in_flash_func(flash_read_sr)(uint8_t cmd) {
    hw_set_bits(&qmi_hw->direct_csr, QMI_DIRECT_CSR_ASSERT_CS0N_BITS);
    (void)qmi_direct_xfer(cmd);
    uint8_t val = qmi_direct_xfer(0x00);
    while (qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS)
        ;
    hw_clear_bits(&qmi_hw->direct_csr, QMI_DIRECT_CSR_ASSERT_CS0N_BITS);
    return val;
}

static void __no_inline_not_in_flash_func(flash_simple_cmd)(uint8_t cmd) {
    hw_set_bits(&qmi_hw->direct_csr, QMI_DIRECT_CSR_ASSERT_CS0N_BITS);
    (void)qmi_direct_xfer(cmd);
    while (qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS)
        ;
    hw_clear_bits(&qmi_hw->direct_csr, QMI_DIRECT_CSR_ASSERT_CS0N_BITS);
}

/* Enable QE bit in W25Q128JV Status Register 2.
 * Returns: 0=already set, 1=just enabled, -1=verify failed.
 * Must be called BEFORE PLL switch (at safe 150 MHz / ROSC speed). */
int __no_inline_not_in_flash_func(overclock_flash_enable_qe)(void) {
    hw_set_bits(&qmi_hw->direct_csr, QMI_DIRECT_CSR_EN_BITS);
    while (qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS)
        ;
    qmi_drain_rx();

    uint8_t sr2 = flash_read_sr(0x35);
    int result = 0;

    if (!(sr2 & 0x02)) {
        flash_simple_cmd(0x06); /* Write Enable */

        /* Write Status Register 2 (cmd 0x31) */
        hw_set_bits(&qmi_hw->direct_csr, QMI_DIRECT_CSR_ASSERT_CS0N_BITS);
        (void)qmi_direct_xfer(0x31);
        (void)qmi_direct_xfer(sr2 | 0x02);
        while (qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS)
            ;
        hw_clear_bits(&qmi_hw->direct_csr, QMI_DIRECT_CSR_ASSERT_CS0N_BITS);

        /* Wait for write to complete */
        while (flash_read_sr(0x05) & 0x01)
            ;

        sr2 = flash_read_sr(0x35);
        result = (sr2 & 0x02) ? 1 : -1;
    }

    hw_clear_bits(&qmi_hw->direct_csr, QMI_DIRECT_CSR_EN_BITS);
    return result;
}

/* ---- Atomic PLL + QMI switch from RAM ---- */

void __no_inline_not_in_flash_func(overclock_apply)(
    uint32_t vco_freq, uint32_t post_div1, uint32_t post_div2,
    uint32_t qmi_timing, uint32_t qmi_rfmt, uint32_t qmi_rcmd)
{
    /* 1. Move clk_sys off PLL: clk_sys → clk_ref → ROSC */
    hw_clear_bits(&clocks_hw->clk[clk_sys].ctrl, CLOCKS_CLK_SYS_CTRL_SRC_BITS);
    while (!(clocks_hw->clk[clk_sys].selected & 1u))
        ;
    hw_clear_bits(&clocks_hw->clk[clk_ref].ctrl, CLOCKS_CLK_REF_CTRL_SRC_BITS);
    while (!(clocks_hw->clk[clk_ref].selected & 1u))
        ;

    /* 2. Reconfigure PLL_SYS */
    uint32_t fbdiv = vco_freq / 12000000u;
    pll_sys_hw->cs = 1; /* REFDIV=1 */
    pll_sys_hw->fbdiv_int = fbdiv;
    pll_sys_hw->pwr = 0xFFFFFFFF;
    hw_clear_bits(&pll_sys_hw->pwr, PLL_PWR_PD_BITS | PLL_PWR_VCOPD_BITS);
    while (!(pll_sys_hw->cs & PLL_CS_LOCK_BITS))
        ;
    pll_sys_hw->prim = (post_div1 << PLL_PRIM_POSTDIV1_LSB) |
                       (post_div2 << PLL_PRIM_POSTDIV2_LSB);
    hw_clear_bits(&pll_sys_hw->pwr, PLL_PWR_POSTDIVPD_BITS);

    /* 3. Write QMI config BEFORE switching clk_sys back to PLL */
    qmi_hw->m[0].timing = qmi_timing;
    qmi_hw->m[0].rfmt   = qmi_rfmt;
    qmi_hw->m[0].rcmd   = qmi_rcmd;

    /* 4. Restore clk_ref → XOSC (SRC=2 on RP2350) */
    hw_write_masked(&clocks_hw->clk[clk_ref].ctrl,
                    2u << CLOCKS_CLK_REF_CTRL_SRC_LSB,
                    CLOCKS_CLK_REF_CTRL_SRC_BITS);
    while (!(clocks_hw->clk[clk_ref].selected & (1u << 2)))
        ;

    /* 5. Switch clk_sys → PLL_SYS */
    hw_write_masked(&clocks_hw->clk[clk_sys].ctrl,
                    0 << CLOCKS_CLK_SYS_CTRL_AUXSRC_LSB,
                    CLOCKS_CLK_SYS_CTRL_AUXSRC_BITS);
    hw_set_bits(&clocks_hw->clk[clk_sys].ctrl, CLOCKS_CLK_SYS_CTRL_SRC_BITS);
    while (!(clocks_hw->clk[clk_sys].selected & 2u))
        ;
}

/* --- Flash (M0) rxdelay calibration --------------------------------------- *
 * Sweep all eight QMI_M0 rxdelay values, CRC the same flash region read through
 * the UNCACHED window at each, find the widest run of identical CRC (== the
 * timing-valid sample window) and park rxdelay at its centre. This mirrors the
 * PSRAM (M1) calibration but for the flash side, which the boot formula in
 * computeQmiConfig() under-delays once overclocked (its clkdiv-1 clamp caps
 * rxdelay at half an SCK period instead of tracking the real round-trip).
 *
 * MUST run from RAM: it transiently programs invalid timings on the very bus we
 * fetch code from, so this routine, the CRC helper and their literal pools are
 * all __no_inline_not_in_flash_func, and they touch flash ONLY through the
 * explicit uncached reads below. The XIP cache is flushed before returning so
 * lines fetched at the boot rxdelay are dropped.
 */
static uint32_t __no_inline_not_in_flash_func(qmi_flash_region_crc)(uint32_t words) {
    /* CS0 (flash) uncached/no-alloc window: every access hits the QMI at the
     * current rxdelay instead of being served from the XIP cache. */
    const volatile uint32_t *p = (const volatile uint32_t *)0x14000000u;
    uint32_t crc = 0xFFFFFFFFu;
    for (uint32_t i = 0; i < words; i++) {
        uint32_t w = p[i];
        for (int byte = 0; byte < 4; byte++) {
            crc ^= (w >> (byte * 8)) & 0xFFu;
            for (int b = 0; b < 8; b++)
                crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(crc & 1u)));
        }
    }
    return ~crc;
}

uint32_t __no_inline_not_in_flash_func(overclock_calibrate_flash_rxdelay)(
        uint32_t *out_lo, uint32_t *out_hi) {
    const uint32_t probe_words = 2048u; /* 8 KiB of real (non-uniform) flash content */
    const uint32_t saved = qmi_hw->m[0].timing;
    uint32_t crc[8];

    for (uint32_t d = 0; d < 8u; d++) {
        qmi_hw->m[0].timing =
            (saved & ~QMI_M0_TIMING_RXDELAY_BITS) | (d << QMI_M0_TIMING_RXDELAY_LSB);
        __asm volatile("dsb\n\tisb" ::: "memory");
        crc[d] = qmi_flash_region_crc(probe_words);
    }

    /* Longest run of identical consecutive CRCs is the valid sample window. */
    int run_lo = 0, best_lo = 0, best_len = 1;
    for (int d = 1; d < 8; d++) {
        if (crc[d] == crc[d - 1]) {
            int len = d - run_lo + 1;
            if (len > best_len) { best_len = len; best_lo = run_lo; }
        } else {
            run_lo = d;
        }
    }

    uint32_t chosen;
    if (best_len <= 1) {
        /* Inconclusive sweep — keep the configured timing untouched. */
        qmi_hw->m[0].timing = saved;
        chosen = (saved & QMI_M0_TIMING_RXDELAY_BITS) >> QMI_M0_TIMING_RXDELAY_LSB;
        if (out_lo) *out_lo = 1; /* lo > hi signals "no window" to the caller */
        if (out_hi) *out_hi = 0;
    } else {
        chosen = (uint32_t)best_lo + (uint32_t)(best_len - 1) / 2u;
        qmi_hw->m[0].timing =
            (saved & ~QMI_M0_TIMING_RXDELAY_BITS) | (chosen << QMI_M0_TIMING_RXDELAY_LSB);
        if (out_lo) *out_lo = (uint32_t)best_lo;
        if (out_hi) *out_hi = (uint32_t)(best_lo + best_len - 1);
    }
    __asm volatile("dsb\n\tisb" ::: "memory");

    /* Drop XIP-cache lines fetched at the previous (boot) rxdelay. The bootrom
     * flush runs from ROM and the lookup is force-inlined here, so no flash
     * fetch happens before the cache is clean. */
    rom_flash_flush_cache_fn flush =
        (rom_flash_flush_cache_fn)rom_func_lookup_inline(ROM_FUNC_FLASH_FLUSH_CACHE);
    flush();

    return chosen;
}
