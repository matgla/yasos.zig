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
