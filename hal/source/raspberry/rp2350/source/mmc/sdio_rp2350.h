/** 
 * SDIO_RP2350 - Copyright (c) 2022-2025 Rabbit Hole Computing™
 * 
 * MIT License
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#pragma once
#include <stdint.h>
#include <stdbool.h>

#include "sdio_rp2350_config.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SDIO_OK = 0,
    SDIO_BUSY = 1,
    SDIO_ERR_RESPONSE_TIMEOUT = 2,
    SDIO_ERR_RESPONSE_CRC = 3,
    SDIO_ERR_RESPONSE_CODE = 4,
    SDIO_ERR_DATA_TIMEOUT = 5,
    SDIO_ERR_DATA_CRC = 6,
    SDIO_ERR_WRITE_CRC = 7,
    SDIO_ERR_WRITE_FAIL = 8,
    SDIO_ERR_STOP_TIMEOUT = 9,
    SDIO_ERR_INVALID_PARAM = 10,
} sdio_status_t;

#ifndef SDIO_CRITMSG
#define SDIO_CRITMSG SDIO_ERRMSG
#endif

#ifndef SDIO_ERRMSG
#define SDIO_ERRMSG(txt, arg1, arg2)
#endif

#ifndef SDIO_DBGMSG
#define SDIO_DBGMSG(txt, arg1, arg2)
#endif

#ifndef SDIO_BLOCK_SIZE
#define SDIO_BLOCK_SIZE 512
#endif

#ifndef SDIO_MAX_CMD_RESPONSE_WORDS
#define SDIO_MAX_CMD_RESPONSE_WORDS 16
#endif

#ifndef SDIO_MAX_BLOCKS_PER_REQ
#define SDIO_MAX_BLOCKS_PER_REQ 128
#endif

#ifndef SDIO_CMD_TIMEOUT_US
#define SDIO_CMD_TIMEOUT_US 50
#endif

#ifndef SDIO_TRANSFER_TIMEOUT_US
#define SDIO_TRANSFER_TIMEOUT_US (1000 * 1000)
#endif

#ifndef SDIO_INIT_TIMEOUT_US
#define SDIO_INIT_TIMEOUT_US (1000 * 1000)
#endif

#ifndef SDIO_PIO_IOBASE
# if SDIO_CLK > 31
#  define SDIO_PIO_IOBASE 16
# else
#  define SDIO_PIO_IOBASE 0
# endif
#endif

#ifndef SDIO_GPIO_SLEW
#define SDIO_GPIO_SLEW GPIO_SLEW_RATE_FAST
#endif

#ifndef SDIO_GPIO_DRIVE
#define SDIO_GPIO_DRIVE GPIO_DRIVE_STRENGTH_8MA
#endif

#ifndef SDIO_USE_SDFAT
#define SDIO_USE_SDFAT 0
#endif

#ifndef SDIO_MAX_RETRYCOUNT
#define SDIO_MAX_RETRYCOUNT 1
#endif

#ifndef SDIO_MAX_CLOCK_RATE_EXCEED_PERCENT
#define SDIO_MAX_CLOCK_RATE_EXCEED_PERCENT 5
#endif

#ifndef SDIO_MAX_CMD_CLOCK_RATE_HZ
#define SDIO_MAX_CMD_CLOCK_RATE_HZ 25000000
#endif

#ifndef SDIO_CARD_OCR_MODE
#define SDIO_CARD_OCR_MODE ((1 << 30) | (1 << 28) | (1 << 20))
#endif

#define SDIO_MIN_CMD_CLK_DIVIDER 6
#define SDIO_MAX_CMD_CLK_DIVIDER 65535
#define SDIO_MIN_DATA_CLK_DIVIDER 6
#define SDIO_MAX_DATA_CLK_DIVIDER 65535
#define SDIO_MIN_HS_DATA_CLK_DIVIDER 2
#define SDIO_MAX_HS_DATA_CLK_DIVIDER 15

#define SDIO_FLAG_NO_CRC      0x0001
#define SDIO_FLAG_NO_LOGMSG   0x0002
#define SDIO_FLAG_NO_CMD_TAG  0x0004
#define SDIO_FLAG_STOP_CLK    0x0008

sdio_status_t rp2350_sdio_command_u32(uint8_t command, uint32_t arg, uint32_t *response, uint32_t flags);
sdio_status_t rp2350_sdio_command(uint8_t command, uint32_t arg, void *response, int resp_bytes, uint32_t flags);
sdio_status_t rp2350_sdio_rx_start(uint8_t *buffer, uint32_t num_blocks, uint32_t blocksize);
sdio_status_t rp2350_sdio_rx_poll(uint32_t *blocks_complete);
sdio_status_t rp2350_sdio_tx_start(const uint8_t *buffer, uint32_t num_blocks, uint32_t blocksize);
sdio_status_t rp2350_sdio_tx_poll(uint32_t *blocks_complete);
sdio_status_t rp2350_sdio_stop(void);
bool rp2350_sdio_is_card_busy(void);

typedef enum {
    SDIO_INITIALIZE             = 0,
    SDIO_MMC                    = 1,
    SDIO_STANDARD               = 2,
    SDIO_HIGHSPEED              = 3,
    SDIO_HIGHSPEED_OVERCLOCK    = 4,
} rp2350_sdio_mode_t;

typedef struct {
    rp2350_sdio_mode_t mode;
    bool use_high_speed;
    int cmd_clk_divider;
    int data_clk_divider;
} rp2350_sdio_timing_t;

rp2350_sdio_timing_t rp2350_sdio_get_timing(rp2350_sdio_mode_t mode);
void rp2350_sdio_init(rp2350_sdio_timing_t timing);

#ifdef __cplusplus
} /* extern "C" */
#endif
