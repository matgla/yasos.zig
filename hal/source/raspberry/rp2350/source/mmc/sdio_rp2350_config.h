/* SDIO_RP2350 configuration for yasos.zig
 * Pin assignments for Pimoroni Pico Plus 2:
 *   CLK  = GP5
 *   CMD  = GP18
 *   D0   = GP19
 *   D1   = GP20
 *   D2   = GP21
 *   D3   = GP22
 */

#pragma once

#include <hardware/timer.h>

/* Timer: use hardware timer directly (pico_time .c not compiled) */
#define SDIO_TIME_US()        ((uint32_t)time_us_64())
#define SDIO_ELAPSED_US(start) ((uint32_t)(SDIO_TIME_US() - (start)))

static inline void sdio_busy_wait_us_impl(uint32_t us) {
    uint32_t start = SDIO_TIME_US();
    while (SDIO_ELAPSED_US(start) < us) {}
}
#define SDIO_WAIT_US(x) sdio_busy_wait_us_impl(x)

/* Never exceed the target clock rate.  At 618 MHz sys_clk the default 5 %
 * threshold results in 25.75 MHz which is above the SD specification
 * maximum of 25 MHz for default-speed mode. */
#define SDIO_MAX_CLOCK_RATE_EXCEED_PERCENT 0

/* How long to wait for a command response before declaring it lost. The
 * upstream default of 50 us is a fixed base to which the driver adds an
 * allowance scaled by the command clock, and at the 300 kHz bring-up clock that
 * margin is thin: the 48-bit response alone takes 160 us on the wire, and the
 * spec lets the card wait its full NCR of 64 clocks -- another 213 us -- before
 * it starts sending. Bring-up failed intermittently on exactly that command,
 * ACMD41, reporting a zero response with the driver's error flag set, which is
 * what a lost response looks like from above.
 *
 * This bounds the error path only: a command that answers leaves the wait as
 * soon as its DMA completes, so a generous value costs nothing in the normal
 * case and only makes a genuinely dead command take longer to give up on. */
#define SDIO_CMD_TIMEOUT_US 5000

/* Route the driver's own error reporting to the kernel log. The upstream macro
 * defaults to nothing, so every diagnostic sdio_rp2350.c already contains --
 * command response timeouts, data CRC errors, PIO program problems -- was being
 * discarded, which is why failures in here look like silence from outside.
 * Implemented in mmc_sdio.zig. */
void yasos_sdio_errmsg(const char *txt, uint32_t arg1, uint32_t arg2);
#define SDIO_ERRMSG(txt, arg1, arg2) \
    yasos_sdio_errmsg((txt), (uint32_t)(arg1), (uint32_t)(arg2))

/* Disable SdFat C++ class */
#define SDIO_USE_SDFAT 0

/* PIO block to use */
#define SDIO_PIO  pio1
#define SDIO_SM   0

/* GPIO configuration */
#define SDIO_GPIO_FUNC  GPIO_FUNC_PIO1
#define SDIO_GPIO_CLK_SLEW      GPIO_SLEW_RATE_FAST
#define SDIO_GPIO_CMD_DATA_SLEW GPIO_SLEW_RATE_FAST
#define SDIO_GPIO_CLK_DRIVE     GPIO_DRIVE_STRENGTH_8MA
#define SDIO_GPIO_CMD_DATA_DRIVE GPIO_DRIVE_STRENGTH_8MA

/* DMA channels to use */
#define SDIO_DMACH_A    4
#define SDIO_DMACH_B    5
#define SDIO_DMAIRQ_IDX 1
#define SDIO_DMAIRQ     DMA_IRQ_1

/* GPIO pins. Not fixed here: every board wires the card differently, so the
 * pins are set at run time by rp2350_sdio_set_pins() from the board's
 * MmcConfig.pins (mmc_sdio.zig), before the first rp2350_sdio_init(). The data
 * lines must be consecutive -- D1..D3 follow D0. */
extern uint8_t g_sdio_pin_clk;
extern uint8_t g_sdio_pin_cmd;
extern uint8_t g_sdio_pin_d0;
void rp2350_sdio_set_pins(uint8_t clk, uint8_t cmd, uint8_t d0);

#define SDIO_CLK g_sdio_pin_clk
#define SDIO_CMD g_sdio_pin_cmd
#define SDIO_D0  g_sdio_pin_d0
#define SDIO_D1  (SDIO_D0 + 1)
#define SDIO_D2  (SDIO_D0 + 2)
#define SDIO_D3  (SDIO_D0 + 3)

/* A PIO block sees 32 GPIOs from its base. Pins above 31 (RP2350B) need the
 * base moved to 16, which also means all six pins must sit in 16..47. Defined
 * here so sdio_rp2350.h's compile-time fallback (which compares SDIO_CLK in
 * the preprocessor) is skipped. */
#define SDIO_PIO_IOBASE ((SDIO_CLK > 31 || SDIO_CMD > 31 || SDIO_D3 > 31) ? 16 : 0)
