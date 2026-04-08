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

/* GPIO pins */
#define SDIO_CLK 5
#define SDIO_CMD 18
#define SDIO_D0  19
#define SDIO_D1  20
#define SDIO_D2  21
#define SDIO_D3  22
