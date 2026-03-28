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

/* Implementation of high-speed 4-bit SDIO communication for RP2350.
 *
 * For official SDIO specifications, refer to:
 * https://www.sdcard.org/downloads/pls/
 * "SDIO Physical Layer Simplified Specification Version 9.00"
 * or the version with TOC: https://jpa.kapsi.fi/stuff/other/SDIO_toc.pdf
 */

#include "sdio_rp2350.h"
#include <hardware/pio.h>
#include <hardware/dma.h>
#include <hardware/gpio.h>
#include <hardware/clocks.h>
#include <hardware/structs/scb.h>
#include <string.h>

#include "sdio_rp2350.pio.h"

typedef enum {
    SDIO_IDLE, // No transfer running, sdio_cmd program is giving continuous clock
    SDIO_CLK_STOPPED,  // No transfer running, clock is stopped
    SDIO_RX,        // Reception running
    SDIO_RX_DONE,   // Reception done, clock is stopped (rx can be continued)
    SDIO_TX,        // Transmission running
    SDIO_TX_WAIT_IDLE, // Transmission done, clock is running, waiting for card not busy
    SDIO_TX_DONE,   // Transmission done, clock is stopped (tx can be continued)
} sdio_transfer_state_t;

static struct {
    // Variables for data transfer
    int transfer_state;
    uint32_t transfer_start_time;
    uint32_t *data_buf;   // Destination or source buffer
    uint32_t blocksize;   // Block size for this transfer
    uint32_t blocks_done; // Number of blocks transferred so far
    uint32_t total_blocks; // Total number of blocks to transfer
    uint32_t blocks_checksumed; // Number of blocks that have had CRC calculated
    uint32_t checksum_errors; // Number of checksum errors detected

    // Command and data clock rates
    // Needed for timeout calculation
    uint32_t cmd_clock_hz;
    uint32_t data_clock_hz;
    rp2350_sdio_timing_t timing;

    // Variables for block writes
    uint64_t next_wr_block_checksum;
    uint32_t end_token_buf[3]; // CRC and end token for write block
    sdio_status_t wr_status;
    uint32_t card_response;

    // PIO configuration
    struct {
        uint32_t sdio_cmd;
        uint32_t data_rx;
        uint32_t data_tx;
    } pio_offset;

    struct {
        pio_sm_config sdio_cmd;
        pio_sm_config data_rx;
        pio_sm_config data_tx;
    } pio_cfg;

    // We have to switch between rx/tx programs because they won't
    // both fit in PIO RAM.
    const pio_program_t *pio_loaded_data_prog;
    uint32_t pio_loaded_data_prog_offset;

    // DMA configuration blocks
    // This is used to perform DMA into data buffers and checksum buffers separately.
    struct {
        void * write_addr;
        uint32_t transfer_count;
    } dma_blocks[SDIO_MAX_BLOCKS_PER_REQ * 2];

    // Received checksums for read operations
    struct {
        uint32_t top;
        uint32_t bottom;
    } received_checksums[SDIO_MAX_BLOCKS_PER_REQ + 4];
} g_sdio;

static void rp2350_sdio_dma_irq();
extern void rp2350_install_irq_handler(uint32_t irq_num, void (*handler)(void));
static uint32_t adjust_clk_add_program(const struct pio_program *program, int extra_delay_0, int extra_delay_1);
static void compute_prescaler_delay(int divider, int min_divider, int *prescaler, int *delay);

/*******************************************************
 * Checksum algorithms
 *******************************************************/

// Table lookup for calculating CRC-7 checksum that is used in SDIO command packets.
// Usage:
//    uint8_t crc = 0;
//    crc = crc7_table[crc ^ byte];
//    .. repeat for every byte ..
static const uint8_t crc7_table[256] = {
	0x00, 0x12, 0x24, 0x36, 0x48, 0x5a, 0x6c, 0x7e,	0x90, 0x82, 0xb4, 0xa6, 0xd8, 0xca, 0xfc, 0xee,
	0x32, 0x20, 0x16, 0x04, 0x7a, 0x68, 0x5e, 0x4c,	0xa2, 0xb0, 0x86, 0x94, 0xea, 0xf8, 0xce, 0xdc,
	0x64, 0x76, 0x40, 0x52, 0x2c, 0x3e, 0x08, 0x1a,	0xf4, 0xe6, 0xd0, 0xc2, 0xbc, 0xae, 0x98, 0x8a,
	0x56, 0x44, 0x72, 0x60, 0x1e, 0x0c, 0x3a, 0x28,	0xc6, 0xd4, 0xe2, 0xf0, 0x8e, 0x9c, 0xaa, 0xb8,
	0xc8, 0xda, 0xec, 0xfe, 0x80, 0x92, 0xa4, 0xb6,	0x58, 0x4a, 0x7c, 0x6e, 0x10, 0x02, 0x34, 0x26,
	0xfa, 0xe8, 0xde, 0xcc, 0xb2, 0xa0, 0x96, 0x84,	0x6a, 0x78, 0x4e, 0x5c, 0x22, 0x30, 0x06, 0x14,
	0xac, 0xbe, 0x88, 0x9a, 0xe4, 0xf6, 0xc0, 0xd2,	0x3c, 0x2e, 0x18, 0x0a, 0x74, 0x66, 0x50, 0x42,
	0x9e, 0x8c, 0xba, 0xa8, 0xd6, 0xc4, 0xf2, 0xe0,	0x0e, 0x1c, 0x2a, 0x38, 0x46, 0x54, 0x62, 0x70,
	0x82, 0x90, 0xa6, 0xb4, 0xca, 0xd8, 0xee, 0xfc,	0x12, 0x00, 0x36, 0x24, 0x5a, 0x48, 0x7e, 0x6c,
	0xb0, 0xa2, 0x94, 0x86, 0xf8, 0xea, 0xdc, 0xce,	0x20, 0x32, 0x04, 0x16, 0x68, 0x7a, 0x4c, 0x5e,
	0xe6, 0xf4, 0xc2, 0xd0, 0xae, 0xbc, 0x8a, 0x98,	0x76, 0x64, 0x52, 0x40, 0x3e, 0x2c, 0x1a, 0x08,
	0xd4, 0xc6, 0xf0, 0xe2, 0x9c, 0x8e, 0xb8, 0xaa,	0x44, 0x56, 0x60, 0x72, 0x0c, 0x1e, 0x28, 0x3a,
	0x4a, 0x58, 0x6e, 0x7c, 0x02, 0x10, 0x26, 0x34,	0xda, 0xc8, 0xfe, 0xec, 0x92, 0x80, 0xb6, 0xa4,
	0x78, 0x6a, 0x5c, 0x4e, 0x30, 0x22, 0x14, 0x06,	0xe8, 0xfa, 0xcc, 0xde, 0xa0, 0xb2, 0x84, 0x96,
	0x2e, 0x3c, 0x0a, 0x18, 0x66, 0x74, 0x42, 0x50,	0xbe, 0xac, 0x9a, 0x88, 0xf6, 0xe4, 0xd2, 0xc0,
	0x1c, 0x0e, 0x38, 0x2a, 0x54, 0x46, 0x70, 0x62,	0x8c, 0x9e, 0xa8, 0xba, 0xc4, 0xd6, 0xe0, 0xf2
};

static uint8_t sdio_crc7(const uint8_t *data, int num_bytes)
{
    uint8_t crc = 0;
    for (int i = 0; i < num_bytes; i++)
    {
        crc = crc7_table[crc ^ data[i]];
    }
    return crc;
}


// Calculate the CRC16 checksum for parallel 4 bit lines separately.
// When the SDIO bus operates in 4-bit mode, the CRC16 algorithm
// is applied to each line separately and generates total of
// 4 x 16 = 64 bits of checksum.
static uint64_t sdio_crc16_4bit_checksum(uint32_t *data, uint32_t num_words)
{
    uint64_t crc = 0;

#if defined(SDIO_CRC_NO_ASM) || !defined(__ARM_ARCH_8M_MAIN__)
    uint32_t *end = data + num_words;
    while (data < end)
    {
        for (int unroll = 0; unroll < 4; unroll++)
        {
            // Each 32-bit word contains 8 bits per line.
            // Reverse the bytes because SDIO protocol is big-endian.
            uint32_t data_in = __builtin_bswap32(*data++);

            // Shift out 8 bits for each line
            uint32_t data_out = crc >> 32;
            crc <<= 32;

#ifdef SDIO_CRC_ELABORATE
            // XOR outgoing data to itself with 4 bit delay
            data_out ^= (data_out >> 16);

            // XOR incoming data to outgoing data with 4 bit delay
            data_out ^= (data_in >> 16);

            // XOR outgoing and incoming data to accumulator at each tap
            uint64_t xorred = data_out ^ data_in;
            crc ^= xorred;
            crc ^= xorred << (5 * 4);
            crc ^= xorred << (12 * 4);
#else
            // This does the same as above, but in a sneakier way
            // XOR outgoing and incoming data to accumulator at each tap
            uint64_t xor32 = data_out ^ data_in;
            xor32 ^= (xor32 >> 16);
            uint64_t xor64 = xor32;
            crc ^= xor64;
            crc ^= xor64 << (5 * 4);
            crc ^= xor64 << (12 * 4);
#endif
        }
    }

#else
    uint32_t clo = 0, chi = 0;

    // Handles 2 words interleaved to avoid result use latency
    __asm__ __volatile__(
        "\n"
        "        ldm %[data]!, {r0, r4}          // Load source words to r0 and r4\n"
        "\n"
        "    1:\n"
        "        rev r0, r0                      //      First word bswap32\n"
        "        eor r1, %[chi], r0              //      xor32 = data_out ^ data_in => r1\n"
        "        subs %[cnt], %[cnt], #2         // num_words -= 2\n"
        "        eor r1, r1, r1, lsr #16         //      xor32 ^= (xor32 >> 16)\n"
        "        eor %[chi], %[clo], r1, lsr #12 //      crc = (crc << 32) ^ (xor64 << 20)\n"
        "        rev r4, r4                      //              Second word bswap32\n"
        "        eor %[chi], %[chi], r1, lsl #16 //      crc ^= xor64 << 48, chi is now done\n"
        "        eor %[clo], r1, r1, lsl #20     //      crc ^= xor64 << 20 (low part)\n"
        "        eor r5, %[chi], r4              //              xor32 = data_out ^ data_in => r5\n"
        "        ldm %[data]!, {r0, r4}          // Load next source words to r0 and r4\n"
        "        eor r5, r5, r5, lsr #16         //              xor32 ^= (xor32 >> 16)\n"
        "        eor %[chi], %[clo], r5, lsr #12 //              crc = (crc << 32) ^ (xor64 << 20)\n"
        "        eor %[clo], r5, r5, lsl #20     //              crc ^= xor64 << 20 (low part)\n"
        "        eor %[chi], %[chi], r5, lsl #16 //              crc ^= xor64 << 48, chi is now done\n"
        "        bne 1b                          // Loop until num_words = 0\n"
        "\n"
    : [cnt] "+r"(num_words), [data] "+r"(data), [clo] "+r"(clo), [chi] "+r"(chi)
       : : "r0", "r1", "r4", "r5", "memory");

    crc = ((uint64_t)chi << 32) | clo;
#endif

    return crc;
}

/*******************************************************
 * Basic SDIO command execution
 *******************************************************/

// This function can be used to hold CLK high while configuring state machines
// Otherwise the side set pin can cause glitches when executing setup instructions
static void sdio_enable_clk(bool enable)
{
    if (enable)
    {
        gpio_set_outover(SDIO_CLK, GPIO_OVERRIDE_NORMAL);
    }
    else
    {
        gpio_set_outover(SDIO_CLK, GPIO_OVERRIDE_HIGH);
    }
}

sdio_status_t rp2350_sdio_command_u32(uint8_t command, uint32_t arg, uint32_t *response, uint32_t flags)
{
    uint32_t tmpbuf;
    sdio_status_t stat = rp2350_sdio_command(command, arg, &tmpbuf, 4, flags);
    tmpbuf = __builtin_bswap32(tmpbuf);

    SDIO_DBGMSG("Command complete", command, tmpbuf);

    if (response)
    {
        *response = tmpbuf;
    }

    return stat;
}

sdio_status_t rp2350_sdio_command(uint8_t command, uint32_t arg, void *response, int resp_bytes, uint32_t flags)
{
    if (g_sdio.transfer_state != SDIO_IDLE)
    {
        rp2350_sdio_stop();
    }

    SDIO_DBGMSG("SDIO Command start", command, arg);

    // Format the arguments in the way expected by the PIO code.
    uint32_t word0 =
        (47 << 24) | // Number of bits in command minus one
        ( 1 << 22) | // Transfer direction from host to card
        (command << 16) | // Command byte
        (((arg >> 24) & 0xFF) << 8) | // MSB byte of argument
        (((arg >> 16) & 0xFF) << 0);
    
    uint32_t word1 =
        (((arg >> 8) & 0xFF) << 24) |
        (((arg >> 0) & 0xFF) << 16) | // LSB byte of argument
        ( 1 << 8); // End bit
    
    // Set number of bits in response minus one, or leave at 0 if no response expected
    if (resp_bytes == 0) flags |= SDIO_FLAG_NO_CRC | SDIO_FLAG_NO_CMD_TAG;
    int response_bits = (resp_bytes > 0) ? (resp_bytes * 8 + 16) : 0; // +16 for start and end token
    uint32_t response_words = (response_bits + 31) / 32;
    if (response_bits > 0)
    {
        word1 |= ((response_bits - 2) << 0);
    }
    else
    {
        response_words = 1; // Just a tag to indicate transmission complete
    }

    // Calculate checksum in the order that the bytes will be transmitted (big-endian)
    uint8_t crc = 0;
    crc = crc7_table[crc ^ ((word0 >> 16) & 0xFF)];
    crc = crc7_table[crc ^ ((word0 >>  8) & 0xFF)];
    crc = crc7_table[crc ^ ((word0 >>  0) & 0xFF)];
    crc = crc7_table[crc ^ ((word1 >> 24) & 0xFF)];
    crc = crc7_table[crc ^ ((word1 >> 16) & 0xFF)];
    word1 |= crc << 8;
    
    // Initialize state machine
    pio_sm_clear_fifos(SDIO_PIO, SDIO_SM);
    pio_sm_exec(SDIO_PIO, SDIO_SM, pio_encode_jmp(g_sdio.pio_offset.sdio_cmd) | pio_encode_sideset(1, 1));
    pio_sm_set_enabled(SDIO_PIO, SDIO_SM, true);

    // Use DMA for reception to support long responses
    uint32_t dma_buf[SDIO_MAX_CMD_RESPONSE_WORDS];
    assert(response_words < SDIO_MAX_CMD_RESPONSE_WORDS);
    dma_channel_config dmacfg = dma_channel_get_default_config(SDIO_DMACH_A);
    channel_config_set_transfer_data_size(&dmacfg, DMA_SIZE_32);
    channel_config_set_read_increment(&dmacfg, false);
    channel_config_set_write_increment(&dmacfg, true);
    channel_config_set_dreq(&dmacfg, pio_get_dreq(SDIO_PIO, SDIO_SM, false));
    dma_channel_configure(SDIO_DMACH_A, &dmacfg, &dma_buf, &SDIO_PIO->rxf[SDIO_SM], response_words, true);
    
    if (flags & SDIO_FLAG_STOP_CLK)
    {
        // Stop sending clock pulses after the response is done
        g_sdio.transfer_state = SDIO_CLK_STOPPED;
        pio_sm_set_wrap(SDIO_PIO, SDIO_SM,
            g_sdio.pio_offset.sdio_cmd + sdio_cmd_offset_resp_done,
            g_sdio.pio_offset.sdio_cmd + sdio_cmd_wrap);
    }

    // Transmit command
    pio_sm_put(SDIO_PIO, SDIO_SM, word0);
    pio_sm_put(SDIO_PIO, SDIO_SM, word1);

    // Calculate the timeout, taking into account the clock rate
    // Command takes 48 bits, response N bits and add 64 bit times for card latency.
    uint32_t timeout = SDIO_CMD_TIMEOUT_US;
    if (g_sdio.cmd_clock_hz > 0)
    {
        timeout += (uint32_t)(64 + 48 + response_bits) * 1000000 / g_sdio.cmd_clock_hz;
    }

    // Wait for response
    uint32_t start = SDIO_TIME_US();
    while (dma_channel_is_busy(SDIO_DMACH_A))
    {
        if (SDIO_ELAPSED_US(start) > timeout)
        {
            if (!dma_channel_is_busy(SDIO_DMACH_A))
            {
                break; // Busy condition cleared in between (delay due to interrupt handler?)
            }

            if (!(flags & SDIO_FLAG_NO_LOGMSG))
            {
                SDIO_ERRMSG("Timeout waiting for command response", command,
                    (SDIO_PIO->flevel) << 16 | (dma_hw->ch[SDIO_DMACH_A].transfer_count));
            }

            // Reset the state machine program
            dma_channel_abort(SDIO_DMACH_A);
            pio_sm_clear_fifos(SDIO_PIO, SDIO_SM);
            pio_sm_exec(SDIO_PIO, SDIO_SM, pio_encode_jmp(g_sdio.pio_offset.sdio_cmd));
            return SDIO_ERR_RESPONSE_TIMEOUT;
        }
    }

    // Extract response bytes from the PIO output words.
    // First byte on wire is highest byte in each word.
    uint8_t data[SDIO_MAX_CMD_RESPONSE_WORDS * 4];
    int total_bytes = (response_bits / 8);
    for (int i = 0; i < total_bytes; i++)
    {
        if (i >= (total_bytes / 4) * 4)
        {
            // Last word is not fully filled, take the lowest bytes
            int remainder = total_bytes % 4;
            data[i] = dma_buf[i / 4] >> ((remainder - 1 - (i % 4)) * 8);
        }
        else
        {
            data[i] = dma_buf[i / 4] >> ((3 - (i % 4)) * 8);
        }
    }
    
    if (resp_bytes > 0)
    {
        if (!(flags & SDIO_FLAG_NO_CRC))
        {
            uint8_t crc = sdio_crc7(data, total_bytes - 1);
            uint8_t expected = data[total_bytes - 1] & 0xFE;

            if (crc != expected)
            {
                SDIO_ERRMSG("SDIO Command response CRC error", dma_buf[0], ((uint32_t)crc << 16) | expected);
                return SDIO_ERR_RESPONSE_CRC;
            }
        }

        if (!(flags & SDIO_FLAG_NO_CMD_TAG) && data[0] != command)
        {
            SDIO_ERRMSG("SDIO Command received wrong reply tag", command, dma_buf[0]);
            return SDIO_ERR_RESPONSE_CODE;
        }

        memcpy(response, data + 1, resp_bytes);
    }

    return SDIO_OK;
}

/*******************************************************
 * Data reception from SD card
 *******************************************************/

static void load_pio_data_rx_program()
{
    const struct pio_program *program;

    // Figure which data transfer PIO program we need
    if (!g_sdio.timing.use_high_speed)
        program = &sdio_data_rx_program;
    else if (g_sdio.timing.data_clk_divider >= 3)
        program = &sdio_data_rx_hs_program;
    else
        program = &sdio_data_rx_hs_oc_program;

    if (program == g_sdio.pio_loaded_data_prog)
    {
        // Already loaded
        return;
    }

    if (g_sdio.pio_loaded_data_prog != NULL)
    {
        // Unload previous program
        pio_remove_program(SDIO_PIO, g_sdio.pio_loaded_data_prog, g_sdio.pio_loaded_data_prog_offset);
        g_sdio.pio_loaded_data_prog = NULL;
    }

    if (program == &sdio_data_rx_program)
    {
        // The standard speed program implements clock dividers >= 6.
        // Standard speed delays can be adjusted on both edges
        int prescaler, delay;
        compute_prescaler_delay(g_sdio.timing.data_clk_divider, SDIO_MIN_DATA_CLK_DIVIDER, &prescaler, &delay);
        int delay0 = delay / 2;
        int delay1 = delay - delay0;
        SDIO_DBGMSG("SDIO data clock adjustment", delay0, delay1);
        g_sdio.pio_offset.data_rx = adjust_clk_add_program(program, delay0, delay1);

        // Data reception program config
        pio_sm_config cfg = sdio_data_rx_program_get_default_config(g_sdio.pio_offset.data_rx);
        sm_config_set_in_pins(&cfg, SDIO_D0);
        sm_config_set_sideset_pins(&cfg, SDIO_CLK);
        sm_config_set_jmp_pin(&cfg, SDIO_D0);
        sm_config_set_clkdiv_int_frac(&cfg, prescaler, 0);
        g_sdio.pio_cfg.data_rx = cfg;

        // Reception clock speed for timeout calculation
        g_sdio.data_clock_hz = clock_get_hz(clk_sys) / prescaler / (delay + SDIO_MIN_DATA_CLK_DIVIDER);
    }
    else if (program == &sdio_data_rx_hs_program)
    {
        // The main high-speed data program implements clock dividers >= 3.
        // High-speed data instruction delays should be adjusted only on CLK=0 state.
        int delay0 = (g_sdio.timing.data_clk_divider - 3);
        SDIO_DBGMSG("SDIO HS data clock adjustment", delay0, 0);
        g_sdio.pio_offset.data_rx = adjust_clk_add_program(&sdio_data_rx_hs_program, delay0, 0);

        // Data reception program config
        pio_sm_config cfg = sdio_data_rx_hs_program_get_default_config(g_sdio.pio_offset.data_rx);
        sm_config_set_in_pins(&cfg, SDIO_D0);
        sm_config_set_sideset_pins(&cfg, SDIO_CLK);
        sm_config_set_jmp_pin(&cfg, SDIO_D0);
        g_sdio.pio_cfg.data_rx = cfg;

        g_sdio.data_clock_hz = clock_get_hz(clk_sys) / (delay0 + 3);
    }
    else
    {
        // High-speed overclock mode always uses /2 divider.
        g_sdio.pio_offset.data_rx = pio_add_program(SDIO_PIO, &sdio_data_rx_hs_oc_program);

        // Data reception program config
        pio_sm_config cfg = sdio_data_rx_hs_oc_program_get_default_config(g_sdio.pio_offset.data_rx);
        sm_config_set_in_pins(&cfg, SDIO_D0);
        sm_config_set_sideset_pins(&cfg, SDIO_CLK);
        sm_config_set_jmp_pin(&cfg, SDIO_D0);
        g_sdio.pio_cfg.data_rx = cfg;

        g_sdio.data_clock_hz = clock_get_hz(clk_sys) / 2;
    }

    g_sdio.pio_loaded_data_prog = program;
    g_sdio.pio_loaded_data_prog_offset = g_sdio.pio_offset.data_rx;
}

sdio_status_t rp2350_sdio_rx_start(uint8_t *buffer, uint32_t num_blocks, uint32_t blocksize)
{
    // Buffer must be aligned
    if (((uint32_t)buffer & 3) != 0 || num_blocks > SDIO_MAX_BLOCKS_PER_REQ)
    {
        return SDIO_ERR_INVALID_PARAM;
    }

    // If we are continuing a previous transfer, we don't
    // need to reinitialize PIO and DMA.
    if (g_sdio.transfer_state != SDIO_RX_DONE)
    {
        sdio_enable_clk(false);
        pio_sm_set_enabled(SDIO_PIO, SDIO_SM, false);
        pio_sm_clear_fifos(SDIO_PIO, SDIO_SM);
        load_pio_data_rx_program();

        // Preconfigure first DMA channel for reading from the PIO RX fifo
        dma_channel_config dmacfg = dma_channel_get_default_config(SDIO_DMACH_A);
        channel_config_set_transfer_data_size(&dmacfg, DMA_SIZE_32);
        channel_config_set_read_increment(&dmacfg, false);
        channel_config_set_write_increment(&dmacfg, true);
        channel_config_set_dreq(&dmacfg, pio_get_dreq(SDIO_PIO, SDIO_SM, false));
        channel_config_set_bswap(&dmacfg, true);
        channel_config_set_chain_to(&dmacfg, SDIO_DMACH_B);
        dma_channel_configure(SDIO_DMACH_A, &dmacfg, 0, &SDIO_PIO->rxf[SDIO_SM], 0, false);

        // Preconfigure second DMA channel for reconfiguring the first one
        dmacfg = dma_channel_get_default_config(SDIO_DMACH_B);
        channel_config_set_transfer_data_size(&dmacfg, DMA_SIZE_32);
        channel_config_set_read_increment(&dmacfg, true);
        channel_config_set_write_increment(&dmacfg, true);
        channel_config_set_ring(&dmacfg, true, 3);
        dma_channel_configure(SDIO_DMACH_B, &dmacfg, &dma_hw->ch[SDIO_DMACH_A].al1_write_addr,
            g_sdio.dma_blocks, 2, false);

        // Initialize PIO state machine
        pio_sm_init(SDIO_PIO, SDIO_SM, g_sdio.pio_offset.data_rx, &g_sdio.pio_cfg.data_rx);
        pio_sm_set_consecutive_pindirs(SDIO_PIO, SDIO_SM, SDIO_D0, 4, false);

        // Write number of nibbles to receive to Y register
        // 2 per byte, plus 16 for checksum, plus 8 for trailing clocks
        // minus one because how PIO counter works
        int nibbles = blocksize * 2 + 16 + 8 - 1;

        // In high speed mode, one extra clock edge is issued after capturing the last nibble,
        // so subtract one. In overclock mode, two extra edges.
        if (g_sdio.pio_loaded_data_prog == &sdio_data_rx_hs_program)
            nibbles -= 1;
        else if (g_sdio.pio_loaded_data_prog == &sdio_data_rx_hs_oc_program)
            nibbles -= 2;

        pio_sm_put(SDIO_PIO, SDIO_SM, nibbles);
        pio_sm_exec(SDIO_PIO, SDIO_SM, pio_encode_out(pio_y, 32) | pio_encode_sideset(1, 1));

        // Enable RX FIFO join because we don't need the TX FIFO during transfer.
        // This gives more leeway for the DMA block switching
        SDIO_PIO->sm[SDIO_SM].shiftctrl |= PIO_SM0_SHIFTCTRL_FJOIN_RX_BITS;
    }

    g_sdio.transfer_state = SDIO_RX;
    g_sdio.transfer_start_time = SDIO_TIME_US();
    g_sdio.data_buf = (uint32_t*)buffer;
    g_sdio.blocks_done = 0;
    g_sdio.blocksize = blocksize;
    g_sdio.total_blocks = num_blocks;
    g_sdio.blocks_checksumed = 0;
    g_sdio.checksum_errors = 0;

    // Start first block reception as soon as possible, to avoid latency
    // caused by initializing the dma blocks. By setting first DMA block to
    // NULL values, we ensure the DMA stops if the transfer completes before
    // next block is ready.
    g_sdio.dma_blocks[0].transfer_count = 0;
    g_sdio.dma_blocks[0].write_addr = 0;
    dma_channel_set_read_addr(SDIO_DMACH_B, g_sdio.dma_blocks, false);

    // IRQ handler will verify checksums
    dma_irqn_set_channel_enabled(SDIO_DMAIRQ_IDX, SDIO_DMACH_B, true);

    uint32_t words_per_block = blocksize / 4;
    dma_channel_set_trans_count(SDIO_DMACH_A, words_per_block, false);
    dma_channel_set_write_addr(SDIO_DMACH_A, buffer, true);

    // Start the state machine
    sdio_enable_clk(true);
    pio_sm_set_enabled(SDIO_PIO, SDIO_SM, true);

    if (num_blocks > 1)
    {
        // Create DMA block descriptors to automatically start next block when previous
        // completes.
        for (int i = 0; i < num_blocks; i++)
        {
            if (i > 0)
            {
                // Copy block data
                g_sdio.dma_blocks[i * 2].write_addr = buffer + i * blocksize;
                g_sdio.dma_blocks[i * 2].transfer_count = blocksize / sizeof(uint32_t);
            }

            if (i < num_blocks - 1)
            {
                // Copy the checksum from the FIFO
                // There is one extra word for the trailing clocks, this dummy value can go over the next checksum.
                // This starts up the next reception
                g_sdio.dma_blocks[i * 2 + 1].write_addr = &g_sdio.received_checksums[i];
                g_sdio.dma_blocks[i * 2 + 1].transfer_count = 3;
            }
            else
            {
                // The checksum for last block will be left in the FIFO.
                // This keeps the state machine stopped after last block.
                g_sdio.dma_blocks[i * 2 + 1].write_addr = 0;
                g_sdio.dma_blocks[i * 2 + 1].transfer_count = 0;
            }
        }

        dma_channel_set_read_addr(SDIO_DMACH_B, &g_sdio.dma_blocks[1], false);

        if (!dma_channel_is_busy(SDIO_DMACH_A))
        {
            SDIO_DBGMSG("Block transfer finished before DMA descriptors were done", 0, 0);
            dma_channel_start(SDIO_DMACH_B);
        }
    }

    return SDIO_OK;
}

static void sdio_update_rx_blocks_done()
{
    if (g_sdio.blocks_done == g_sdio.total_blocks)
    {
        // Already done
        return;
    }

    // Check how many DMA control blocks have been consumed
    uint32_t dma_ctrl_block_count = (dma_hw->ch[SDIO_DMACH_B].read_addr - (uint32_t)g_sdio.dma_blocks);
    dma_ctrl_block_count /= sizeof(g_sdio.dma_blocks[0]);

    // Compute how many complete 512 byte SDIO blocks have been transferred
    // When transfer ends, dma_ctrl_block_count == g_sdio.total_blocks * 2
    // but the last checksum isn't yet done.
    uint32_t blocks_done_dma = 0;
    if (dma_ctrl_block_count > 1)
        blocks_done_dma = (dma_ctrl_block_count - 1) / 2;

    // Check if the DMA is all done.
    // For single block transfers we have only one DMA control block (the null one)
    if (dma_ctrl_block_count == g_sdio.total_blocks * 2 ||
        (dma_ctrl_block_count == 1 && g_sdio.total_blocks == 1))
    {
        // All blocks are done, but we still need the last checksum
        // before we update g_sdio.blocks_done. We cannot use DMA
        // easily here because we need to stop the clock before
        // reading the FIFO. But normally the checksum has already
        // been received during the IRQ latency.
        uint32_t start = SDIO_TIME_US();
        int timeout = SDIO_CMD_TIMEOUT_US;
        if (g_sdio.data_clock_hz > 0) timeout += 20 * 1000000 / g_sdio.data_clock_hz;
        while (pio_sm_get_rx_fifo_level(SDIO_PIO, SDIO_SM) < 3)
        {
            if (SDIO_ELAPSED_US(start) > timeout)
            {
                SDIO_ERRMSG("Checksum reception timeout", pio_sm_get_rx_fifo_level(SDIO_PIO, SDIO_SM), 0);
                g_sdio.checksum_errors++;
                break;
            }
        }

        // Stop the clock and copy last checksum from PIO FIFO.
        sdio_enable_clk(false);
        pio_sm_set_enabled(SDIO_PIO, SDIO_SM, false);

        // DMA is set to byte-swap the data, so we need to byte swap
        // these manually so that it will match.
        g_sdio.received_checksums[g_sdio.total_blocks - 1].top = __builtin_bswap32(SDIO_PIO->rxf[SDIO_SM]);
        g_sdio.received_checksums[g_sdio.total_blocks - 1].bottom = __builtin_bswap32(SDIO_PIO->rxf[SDIO_SM]);
        (void)SDIO_PIO->rxf[SDIO_SM];

        g_sdio.blocks_done = g_sdio.total_blocks;
    }
    else
    {
        // Not all blocks are yet done, but report to application the status
        g_sdio.blocks_done = blocks_done_dma;
    }
}

// Check checksums for received blocks
// Called from interrupt
static void sdio_verify_rx_checksums()
{
    while (g_sdio.blocks_checksumed < g_sdio.blocks_done)
    {
        // Calculate checksum from received data
        int blockidx = g_sdio.blocks_checksumed++;
        uint32_t words_per_block = g_sdio.blocksize / 4;
        uint64_t checksum = sdio_crc16_4bit_checksum(g_sdio.data_buf + blockidx * words_per_block,
                                                     words_per_block);

        // Convert received checksum to little-endian format
        uint32_t top = __builtin_bswap32(g_sdio.received_checksums[blockidx].top);
        uint32_t bottom = __builtin_bswap32(g_sdio.received_checksums[blockidx].bottom);
        uint64_t expected = ((uint64_t)top << 32) | bottom;

        if (checksum != expected)
        {
            g_sdio.checksum_errors++;
            if (g_sdio.checksum_errors == 1)
            {
                SDIO_ERRMSG("SDIO checksum error in data reception", (uint32_t)checksum, bottom);
            }
        }

        // The checksums have now been read and shouldn't be mistaken for any other block
        g_sdio.received_checksums[blockidx].top = 0xDEADBEEF;
        g_sdio.received_checksums[blockidx].bottom = 0xDEADBEEF;
    }
}

// Check if reception is complete
// Returns SDIO_BUSY while transferring, SDIO_OK when done and error on failure.
sdio_status_t rp2350_sdio_rx_poll(uint32_t *blocks_complete)
{
    // Always call DMA IRQ handler in polled mode.
    // The DMA interrupt may not fire in environments that manage
    // their own interrupt vector table (e.g. an RTOS).
    rp2350_sdio_dma_irq();

    if (blocks_complete)
    {
        *blocks_complete = g_sdio.blocks_done;
    }

    if (g_sdio.checksum_errors > 0)
    {
        SDIO_ERRMSG("SDIO checksum error in read", g_sdio.blocks_checksumed, g_sdio.total_blocks);
        rp2350_sdio_stop();
        return SDIO_ERR_DATA_CRC;
    }

    if (g_sdio.blocks_checksumed == g_sdio.total_blocks)
    {
        g_sdio.transfer_state = SDIO_RX_DONE;
    }

    if (g_sdio.transfer_state == SDIO_RX_DONE || g_sdio.transfer_state == SDIO_IDLE)
    {
        return SDIO_OK;
    }
    else if (SDIO_ELAPSED_US(g_sdio.transfer_start_time) > SDIO_TRANSFER_TIMEOUT_US)
    {
        SDIO_ERRMSG("SDIO data rx timeout", g_sdio.blocks_done, dma_hw->ch[SDIO_DMACH_A].al2_transfer_count);
        rp2350_sdio_stop();
        return SDIO_ERR_DATA_TIMEOUT;
    }

    return SDIO_BUSY;
}

/*******************************************************
 * Data transmission to SD card
 *******************************************************/

static void load_pio_data_tx_program()
{
    const struct pio_program *program;

    // Figure which data transfer PIO program we need
    if (!g_sdio.timing.use_high_speed)
        program = &sdio_data_tx_program;
    else
        program = &sdio_data_tx_hs_program;

    if (program == g_sdio.pio_loaded_data_prog)
    {
        // Already loaded
        return;
    }

    if (g_sdio.pio_loaded_data_prog != NULL)
    {
        // Unload previous program
        pio_remove_program(SDIO_PIO, g_sdio.pio_loaded_data_prog, g_sdio.pio_loaded_data_prog_offset);
        g_sdio.pio_loaded_data_prog = NULL;
    }

    if (program == &sdio_data_tx_program)
    {
        // The standard speed program implements clock dividers >= 6.
        // Standard speed delays can be adjusted on both edges
        int prescaler, delay;
        compute_prescaler_delay(g_sdio.timing.data_clk_divider, SDIO_MIN_DATA_CLK_DIVIDER, &prescaler, &delay);
        int delay0 = delay / 2;
        int delay1 = delay - delay0;
        SDIO_DBGMSG("SDIO data clock adjustment", delay0, delay1);
        g_sdio.pio_offset.data_tx = adjust_clk_add_program(program, delay0, delay1);

        // Data transmission program config
        pio_sm_config cfg = sdio_data_tx_program_get_default_config(g_sdio.pio_offset.data_tx);
        sm_config_set_in_pins(&cfg, SDIO_D0);
        sm_config_set_set_pins(&cfg, SDIO_D0, 4);
        sm_config_set_out_pins(&cfg, SDIO_D0, 4);
        sm_config_set_jmp_pin(&cfg, SDIO_D0);
        sm_config_set_sideset_pins(&cfg, SDIO_CLK);
        sm_config_set_clkdiv_int_frac(&cfg, prescaler, 0);
        g_sdio.pio_cfg.data_tx = cfg;
    }
    else
    {
        // The high-speed data transmission program implements clock dividers >= 3.
        // High-speed data instruction delays should be adjusted only on CLK=0 state.
        int delay0 = (g_sdio.timing.data_clk_divider - 3);
        if (delay0 < 0) delay0 = 0;
        SDIO_DBGMSG("SDIO HS data clock adjustment", delay0, 0);
        g_sdio.pio_offset.data_tx = adjust_clk_add_program(program, delay0, 0);

        // Data transmission program config
        pio_sm_config cfg = sdio_data_tx_hs_program_get_default_config(g_sdio.pio_offset.data_tx);
        sm_config_set_in_pins(&cfg, SDIO_D0);
        sm_config_set_set_pins(&cfg, SDIO_D0, 4);
        sm_config_set_out_pins(&cfg, SDIO_D0, 4);
        sm_config_set_jmp_pin(&cfg, SDIO_D0);
        sm_config_set_sideset_pins(&cfg, SDIO_CLK);
        g_sdio.pio_cfg.data_tx = cfg;
    }

    g_sdio.pio_loaded_data_prog = program;
    g_sdio.pio_loaded_data_prog_offset = g_sdio.pio_offset.data_tx;
}

static void sdio_start_next_block_tx()
{
    // Prepare second DMA channel to send the CRC and block end marker
    uint64_t crc = g_sdio.next_wr_block_checksum;
    g_sdio.end_token_buf[0] = (uint32_t)(crc >> 32);
    g_sdio.end_token_buf[1] = (uint32_t)(crc >>  0);
    g_sdio.end_token_buf[2] = 0xFFFFFFFF;
    
    sdio_enable_clk(false);
    pio_sm_set_enabled(SDIO_PIO, SDIO_SM, false);

    // Initialize register X with nibble count and register Y with response bit count
    pio_sm_put(SDIO_PIO, SDIO_SM, 8 + 2 * g_sdio.blocksize + 16 + 1 - 1);
    pio_sm_exec(SDIO_PIO, SDIO_SM, pio_encode_out(pio_x, 32));
    pio_sm_exec(SDIO_PIO, SDIO_SM, pio_encode_set(pio_y, 31));

    // Initialize pins to output and high
    pio_sm_exec(SDIO_PIO, SDIO_SM, pio_encode_set(pio_pins, 15));
    pio_sm_exec(SDIO_PIO, SDIO_SM, pio_encode_set(pio_pindirs, 15));

    dma_channel_config dmacfg = dma_channel_get_default_config(SDIO_DMACH_B);
    channel_config_set_transfer_data_size(&dmacfg, DMA_SIZE_32);
    channel_config_set_read_increment(&dmacfg, true);
    channel_config_set_write_increment(&dmacfg, false);
    channel_config_set_dreq(&dmacfg, pio_get_dreq(SDIO_PIO, SDIO_SM, true));
    dma_channel_configure(SDIO_DMACH_B, &dmacfg,
        &SDIO_PIO->txf[SDIO_SM], &g_sdio.end_token_buf, 3, false);

    // Write start token to FIFO directly
    pio_sm_put(SDIO_PIO, SDIO_SM, 0xFFFFFFF0);

    // Start DMA transfer to state machine
    uint32_t words_per_block = g_sdio.blocksize / 4;
    void *src = g_sdio.data_buf + g_sdio.blocks_done * words_per_block;
    dma_channel_set_trans_count(SDIO_DMACH_A, words_per_block, false);
    dma_channel_set_read_addr(SDIO_DMACH_A, src, true);
    
    // Start state machine
    sdio_enable_clk(true);
    pio_sm_set_enabled(SDIO_PIO, SDIO_SM, true);
}

static void sdio_compute_next_tx_checksum()
{
    assert (g_sdio.blocks_done < g_sdio.total_blocks && g_sdio.blocks_checksumed < g_sdio.total_blocks);
    int blockidx = g_sdio.blocks_checksumed++;
    uint32_t words_per_block = g_sdio.blocksize / 4;
    g_sdio.next_wr_block_checksum = sdio_crc16_4bit_checksum(g_sdio.data_buf + blockidx * words_per_block,
                                                             words_per_block);
}

// Start transferring data from memory to SD card
sdio_status_t rp2350_sdio_tx_start(const uint8_t *buffer, uint32_t num_blocks, uint32_t blocksize)
{
    // Buffer must be aligned
    if (((uint32_t)buffer & 3) != 0 || num_blocks > SDIO_MAX_BLOCKS_PER_REQ)
    {
        return SDIO_ERR_INVALID_PARAM;
    }

    // If we are continuing a previous transfer, we don't
    // need to reinitialize PIO and DMA.
    if (g_sdio.transfer_state != SDIO_TX_DONE)
    {
        // Initialize PIO
        sdio_enable_clk(false);
        pio_sm_set_enabled(SDIO_PIO, SDIO_SM, false);
        load_pio_data_tx_program();
        pio_sm_init(SDIO_PIO, SDIO_SM, g_sdio.pio_offset.data_tx, &g_sdio.pio_cfg.data_tx);

        // Preconfigure DMA to send the data block payload
        dma_channel_config dmacfg = dma_channel_get_default_config(SDIO_DMACH_A);
        channel_config_set_transfer_data_size(&dmacfg, DMA_SIZE_32);
        channel_config_set_read_increment(&dmacfg, true);
        channel_config_set_write_increment(&dmacfg, false);
        channel_config_set_dreq(&dmacfg, pio_get_dreq(SDIO_PIO, SDIO_SM, true));
        channel_config_set_bswap(&dmacfg, true);
        channel_config_set_chain_to(&dmacfg, SDIO_DMACH_B);
        dma_channel_configure(SDIO_DMACH_A, &dmacfg,
            &SDIO_PIO->txf[SDIO_SM], 0, 0, false);
    }

    g_sdio.transfer_state = SDIO_TX;
    g_sdio.transfer_start_time = SDIO_TIME_US();
    g_sdio.data_buf = (uint32_t*)buffer;
    g_sdio.blocks_done = 0;
    g_sdio.blocksize = blocksize;
    g_sdio.total_blocks = num_blocks;
    g_sdio.blocks_checksumed = 0;
    g_sdio.checksum_errors = 0;

    // Compute first block checksum
    sdio_compute_next_tx_checksum();

    // Interrupt mustn't fire before block checksum calculation is complete
    dma_irqn_acknowledge_channel(SDIO_DMAIRQ_IDX, SDIO_DMACH_B);
    dma_irqn_set_channel_enabled(SDIO_DMAIRQ_IDX, SDIO_DMACH_B, false);

    // Start first DMA transfer and PIO
    sdio_start_next_block_tx();

    if (g_sdio.blocks_checksumed < g_sdio.total_blocks)
    {
        // Precompute second block checksum
        sdio_compute_next_tx_checksum();
    }

    // Enable IRQ to trigger when block is done (it may already be)
    dma_irqn_set_channel_enabled(SDIO_DMAIRQ_IDX, SDIO_DMACH_B, true);

    return SDIO_OK;
}

sdio_status_t check_sdio_write_response(uint32_t card_response)
{
    // Shift card response until top bit is 0 (the start bit)
    // The format of response is poorly documented in SDIO spec but refer to e.g.
    // http://my-cool-projects.blogspot.com/2013/02/the-mysterious-sd-card-crc-status.html
    uint32_t resp = card_response;
    if (!(~resp & 0xFFFF0000)) resp <<= 16;
    if (!(~resp & 0xFF000000)) resp <<= 8;
    if (!(~resp & 0xF0000000)) resp <<= 4;
    if (!(~resp & 0xC0000000)) resp <<= 2;
    if (!(~resp & 0x80000000)) resp <<= 1;

    uint32_t wr_status = (resp >> 28) & 7;

    if (wr_status == 2)
    {
        return SDIO_OK;
    }
    else if (wr_status == 5)
    {
        SDIO_ERRMSG("SDIO data write CRC error", card_response, g_sdio.blocks_done);
        return SDIO_ERR_WRITE_CRC;    
    }
    else if (wr_status == 6)
    {
        SDIO_ERRMSG("SDIO data write failure", card_response, g_sdio.blocks_done);
        return SDIO_ERR_WRITE_FAIL;    
    }
    else
    {
        SDIO_ERRMSG("SDIO data unknown write status", card_response, g_sdio.blocks_done);
        return SDIO_ERR_WRITE_FAIL;    
    }
}

// When a block finishes, this IRQ handler starts the next one
static void rp2350_sdio_dma_irq()
{
    dma_irqn_acknowledge_channel(SDIO_DMAIRQ_IDX, SDIO_DMACH_B);

    if (g_sdio.transfer_state == SDIO_RX)
    {
        sdio_update_rx_blocks_done();
        sdio_verify_rx_checksums();
    }

    if (g_sdio.transfer_state == SDIO_TX)
    {
        if (!dma_channel_is_busy(SDIO_DMACH_A) && !dma_channel_is_busy(SDIO_DMACH_B))
        {
            // Main data transfer is finished now.
            // When card is ready, PIO will put card response on RX fifo
            g_sdio.transfer_state = SDIO_TX_WAIT_IDLE;
            if (!pio_sm_is_rx_fifo_empty(SDIO_PIO, SDIO_SM))
            {
                // Card is already idle
                g_sdio.card_response = pio_sm_get(SDIO_PIO, SDIO_SM);
            }
            else
            {
                // Use DMA to wait for the response
                dma_channel_config dmacfg = dma_channel_get_default_config(SDIO_DMACH_B);
                channel_config_set_transfer_data_size(&dmacfg, DMA_SIZE_32);
                channel_config_set_read_increment(&dmacfg, false);
                channel_config_set_write_increment(&dmacfg, false);
                channel_config_set_dreq(&dmacfg, pio_get_dreq(SDIO_PIO, SDIO_SM, false));
                dma_channel_configure(SDIO_DMACH_B, &dmacfg,
                    &g_sdio.card_response, &SDIO_PIO->rxf[SDIO_SM], 1, true);
            }
        }
    }
    
    if (g_sdio.transfer_state == SDIO_TX_WAIT_IDLE)
    {
        if (!dma_channel_is_busy(SDIO_DMACH_B))
        {
            dma_irqn_acknowledge_channel(SDIO_DMAIRQ_IDX, SDIO_DMACH_B);

            g_sdio.wr_status = check_sdio_write_response(g_sdio.card_response);
            g_sdio.card_response = 0xDEADBEEF;

            if (g_sdio.wr_status != SDIO_OK)
            {
                rp2350_sdio_stop();
                return;
            }

            g_sdio.blocks_done++;
            if (g_sdio.blocks_done < g_sdio.total_blocks)
            {
                sdio_start_next_block_tx();
                g_sdio.transfer_state = SDIO_TX;

                if (g_sdio.blocks_checksumed < g_sdio.total_blocks)
                {
                    // Precompute the CRC for next block so that it is ready when
                    // we want to send it.
                    sdio_compute_next_tx_checksum();
                }
            }
            else
            {
                g_sdio.transfer_state = SDIO_TX_DONE;
            }
        }    
    }
}

// Check if transmission is complete
sdio_status_t rp2350_sdio_tx_poll(uint32_t *blocks_complete)
{
    // Always call DMA IRQ handler in polled mode.
    rp2350_sdio_dma_irq();

    if (blocks_complete)
    {
        *blocks_complete = g_sdio.blocks_done;
    }

    if (g_sdio.transfer_state == SDIO_TX_DONE || g_sdio.transfer_state == SDIO_IDLE)
    {
        return g_sdio.wr_status;
    }
    else if (SDIO_ELAPSED_US(g_sdio.transfer_start_time) > SDIO_TRANSFER_TIMEOUT_US)
    {
        SDIO_ERRMSG("SDIO data tx timeout", g_sdio.blocks_done, dma_hw->ch[SDIO_DMACH_A].al2_transfer_count);
        rp2350_sdio_stop();
        return SDIO_ERR_DATA_TIMEOUT;
    }

    return SDIO_BUSY;
}

// Force everything to idle state
// This requires careful sequencing to cleanly abort any running data transfers.
sdio_status_t rp2350_sdio_stop()
{
    // First disable DMA interrupt handlers
    uint32_t channel_mask = (1 << SDIO_DMACH_A) | (1 << SDIO_DMACH_B);
    dma_irqn_set_channel_mask_enabled(SDIO_DMAIRQ_IDX, channel_mask, false);

    // Then stop the PIO state machine
    sdio_enable_clk(false);
    pio_sm_set_enabled(SDIO_PIO, SDIO_SM, false);
    pio_sm_set_consecutive_pindirs(SDIO_PIO, SDIO_SM, SDIO_D0, 4, false);
    
    // The DMA channels chain to each other, so they must be aborted simultaneously.
    // To ensure both are stopped, they are aborted twice.
    dma_hw->abort = channel_mask;
    while (dma_hw->abort);
    dma_hw->abort = channel_mask;
    while (dma_hw->abort);

    // Re-enable the command state machine
    // This will give continuous clock for the card to use for its own tasks
    pio_sm_init(SDIO_PIO, SDIO_SM, g_sdio.pio_offset.sdio_cmd, &g_sdio.pio_cfg.sdio_cmd);
    pio_sm_clear_fifos(SDIO_PIO, SDIO_SM);
    pio_sm_exec(SDIO_PIO, SDIO_SM, pio_encode_mov(pio_isr, pio_null)); // Make sure ISR is empty
    pio_sm_set_consecutive_pindirs(SDIO_PIO, SDIO_SM, SDIO_CLK, 1, true);
    pio_sm_set_consecutive_pindirs(SDIO_PIO, SDIO_SM, SDIO_CMD, 1, false);
    sdio_enable_clk(true);
    pio_sm_set_enabled(SDIO_PIO, SDIO_SM, true);

    g_sdio.transfer_state = SDIO_IDLE;
    return SDIO_OK;
}

// Adjusts the delay cycles of instructions separately for "side 0" and "side 1" states.
static uint32_t adjust_clk_add_program(const struct pio_program *program, int extra_delay_0, int extra_delay_1)
{
    uint16_t instructions[32];

    for (int i = 0; i < program->length; i++)
    {
        // The instructions should have side set of 1 bit and delay field of 4 bits.
        uint32_t instr = program->instructions[i];
        bool side_set = (instr & (1 << 12));
        int orig_delay = (instr >> 8) & 0x0F;
        int new_delay = orig_delay + (side_set ? extra_delay_1 : extra_delay_0);
        assert(new_delay >= 0 && new_delay <= 15);
        instr &= ~(0x0F << 8);
        instr |= (new_delay << 8);
        instructions[i] = instr;
    }

    struct pio_program new_prog = *program;
    new_prog.instructions = instructions;

    int offset = pio_add_program(SDIO_PIO, &new_prog);
    assert(offset >= 0);
    return offset;
}

static void compute_prescaler_delay(int divider, int min_divider, int *prescaler, int *delay)
{
    if (divider > 16)
    {
        // Use prescaler and delays to achieve the requested divider
        *prescaler = divider / (min_divider * 2);
        *delay = (divider + *prescaler - 1) / *prescaler - min_divider;
    }
    else
    {
        // Use only delays
        *prescaler = 1;
        *delay = divider - min_divider;
    }

    if (*delay < 0) *delay = 0;
}

static uint32_t clamp(uint32_t x, uint32_t min, uint32_t max)
{
    if (x < min) return min;
    if (x > max) return max;
    return x;
}

static uint32_t divide_clockrate(uint32_t sys_clk, uint32_t target_hz)
{
    // Round down the divider, and if that results in too high clock rate,
    // increase the divider by one.
    uint32_t divider = sys_clk / target_hz;
    uint32_t actual_hz = sys_clk / divider;
    int exceed_percent = ((int64_t)actual_hz - (int64_t)target_hz) * 100 / target_hz;
    if (exceed_percent > SDIO_MAX_CLOCK_RATE_EXCEED_PERCENT) divider++;

    return divider;
}

rp2350_sdio_timing_t rp2350_sdio_get_timing(rp2350_sdio_mode_t mode)
{
    rp2350_sdio_timing_t result = {0};
    result.mode = mode;

    uint32_t sys_clk = clock_get_hz(clk_sys);
    uint32_t data_hz = 0;
    
    if (mode == SDIO_INITIALIZE)
    {
        data_hz = 300000;
    }
    else if (mode == SDIO_MMC)
    {
        data_hz = 20000000;
    }
    else if (mode == SDIO_STANDARD)
    {
        data_hz = 25000000;
    }
    else if (mode == SDIO_HIGHSPEED)
    {
        data_hz = 50000000;
        result.use_high_speed = true;
    }
    else if (mode == SDIO_HIGHSPEED_OVERCLOCK)
    {
        data_hz = 75000000;
        result.use_high_speed = true;
    }

    uint32_t cmd_hz = (data_hz < SDIO_MAX_CMD_CLOCK_RATE_HZ) ? data_hz : SDIO_MAX_CMD_CLOCK_RATE_HZ;
    int data_divider = divide_clockrate(sys_clk, data_hz);
    int cmd_divider = divide_clockrate(sys_clk, cmd_hz);

    result.cmd_clk_divider = clamp(cmd_divider, SDIO_MIN_CMD_CLK_DIVIDER, SDIO_MAX_CMD_CLK_DIVIDER);

    if (result.use_high_speed)
    {
        result.data_clk_divider = clamp(data_divider, SDIO_MIN_HS_DATA_CLK_DIVIDER, SDIO_MAX_HS_DATA_CLK_DIVIDER);
    }
    else
    {
        result.data_clk_divider = clamp(data_divider, SDIO_MIN_DATA_CLK_DIVIDER, SDIO_MAX_DATA_CLK_DIVIDER);
    }
    return result;
}

void rp2350_sdio_init(rp2350_sdio_timing_t timing)
{
    SDIO_DBGMSG("SDIO init", timing.cmd_clk_divider, timing.data_clk_divider);

    #if SDIO_PIO_IOBASE > 0
        pio_set_gpio_base(SDIO_PIO, 16);
    #endif

    // Mark resources as being in use, unless it has been done already.
    static bool resources_claimed = false;
    if (!resources_claimed)
    {
        pio_sm_claim(SDIO_PIO, SDIO_SM);
        dma_channel_claim(SDIO_DMACH_A);
        dma_channel_claim(SDIO_DMACH_B);
        resources_claimed = true;
    }

    memset(&g_sdio, 0, sizeof(g_sdio));
    g_sdio.timing = timing;

    // Hold CLK high before stopping SM to prevent glitches that could
    // confuse an already-initialized card during a speed change.
    sdio_enable_clk(false);
    dma_channel_abort(SDIO_DMACH_A);
    dma_channel_abort(SDIO_DMACH_B);
    pio_sm_set_enabled(SDIO_PIO, SDIO_SM, false);
    
    // Clear PIO memory and prepare the command program
    // Data programs are loaded when needed
    pio_clear_instruction_memory(SDIO_PIO);
    g_sdio.pio_loaded_data_prog = NULL;

    {
        // Adjust command clock speed
        int prescaler, delay;
        compute_prescaler_delay(timing.cmd_clk_divider, SDIO_MIN_CMD_CLK_DIVIDER, &prescaler, &delay);
        int delay0 = delay / 2;
        int delay1 = delay - delay0;
        SDIO_DBGMSG("SDIO cmd clock adjustment", delay0, delay1);
        
        // The high speed program differs in active clock edge
        // With slow enough clock, either will work independent of card CMD6 mode.
        if (!timing.use_high_speed)
        {
            g_sdio.pio_offset.sdio_cmd = adjust_clk_add_program(&sdio_cmd_program, delay0, delay1);
        }
        else
        {
            g_sdio.pio_offset.sdio_cmd = adjust_clk_add_program(&sdio_cmd_hs_program, delay0, delay1);
        }

        pio_sm_config cfg = sdio_cmd_program_get_default_config(g_sdio.pio_offset.sdio_cmd);
        sm_config_set_out_pins(&cfg, SDIO_CMD, 1);
        sm_config_set_in_pins(&cfg, SDIO_CMD);
        sm_config_set_set_pins(&cfg, SDIO_CMD, 1);
        sm_config_set_jmp_pin(&cfg, SDIO_CMD);
        sm_config_set_sideset_pins(&cfg, SDIO_CLK);
        sm_config_set_out_shift(&cfg, false, true, 32);
        sm_config_set_in_shift(&cfg, false, true, 32);
        sm_config_set_clkdiv_int_frac(&cfg, prescaler, 0);
        g_sdio.pio_cfg.sdio_cmd = cfg;

        g_sdio.cmd_clock_hz = clock_get_hz(clk_sys) / prescaler / (delay + SDIO_MIN_CMD_CLK_DIVIDER);
    }

    // Only bypass the input synchronizer on the data lines that are timing
    // critical for block transfers. Leave CMD synchronized for better noise
    // tolerance and don't touch CLK because it is output-only from the PIO.
    SDIO_PIO->input_sync_bypass |= (1 << (SDIO_D0 - SDIO_PIO_IOBASE)) | (1 << (SDIO_D1 - SDIO_PIO_IOBASE))
                                 | (1 << (SDIO_D2 - SDIO_PIO_IOBASE)) | (1 << (SDIO_D3 - SDIO_PIO_IOBASE));

    // SDIO idle state requires pull-ups on CMD and DAT lines. Keep the clock
    // line as a pure output, while giving CMD/DAT input hysteresis to improve
    // noise tolerance on the receive path.
    gpio_set_function(SDIO_CLK, SDIO_GPIO_FUNC);
    gpio_set_slew_rate(SDIO_CLK, SDIO_GPIO_CLK_SLEW);
    gpio_set_drive_strength(SDIO_CLK, SDIO_GPIO_CLK_DRIVE);
    gpio_set_pulls(SDIO_CLK, false, false);
    gpio_set_input_hysteresis_enabled(SDIO_CLK, false);
    gpio_set_input_enabled(SDIO_CLK, false);

    int io_pins[5] = {SDIO_CMD, SDIO_D0, SDIO_D1, SDIO_D2, SDIO_D3};
    for (int i = 0; i < 5; i++)
    {
        gpio_set_function(io_pins[i], SDIO_GPIO_FUNC);
        gpio_set_slew_rate(io_pins[i], SDIO_GPIO_CMD_DATA_SLEW);
        gpio_set_drive_strength(io_pins[i], SDIO_GPIO_CMD_DATA_DRIVE);
        gpio_set_pulls(io_pins[i], true, false);
        gpio_set_input_hysteresis_enabled(io_pins[i], true);
        gpio_set_input_enabled(io_pins[i], true);
    }
    
    // Install the handler into the RAM-backed vector table used by yasos.
    // The polled wrapper still calls the handler directly, which keeps SDIO
    // working when the kernel has interrupts masked around a transfer.
    rp2350_install_irq_handler(SDIO_DMAIRQ, rp2350_sdio_dma_irq);
    irq_set_enabled(SDIO_DMAIRQ, true);

    // Go to idle state
    rp2350_sdio_stop();
}
