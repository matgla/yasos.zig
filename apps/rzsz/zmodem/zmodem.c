/*
 Copyright (c) 2025 Mateusz Stadnik

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 of the Software, and to permit persons to whom the Software is furnished to do
 so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

#include "zmodem.h"
#include "frame.h"

#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../crc16.h"
#include "../terminal.h"

#include <sys/klog.h>

#define ZMODEM_DATA_BUF_SIZE 1024
#define ZMODEM_MAX_RETRIES 5

/* ---- low-level I/O helpers ---- */

static void tx_byte(uint8_t b) {
  write(STDOUT_FILENO, &b, 1);
}

static void tx_zdle_encoded(uint8_t b) {
  if (b == ZDLE || b == 0x11 || b == 0x13 ||
      (b < 0x20 && b != 0x0a && b != 0x0d)) {
    tx_byte(ZDLE);
    tx_byte(b ^ 0x40);
  } else {
    tx_byte(b);
  }
}

/* Read one raw byte. Returns -1 on timeout/error. */
static int rx_byte(void) {
  uint8_t b;
  int rc = read(STDIN_FILENO, &b, 1);
  if (rc <= 0)
    return -1;
  return b;
}

/* Read one byte, handling ZDLE escapes. Returns -1 on error. */
static int rx_zdle_byte(void) {
  int b = rx_byte();
  if (b < 0)
    return -1;
  if (b == ZDLE) {
    b = rx_byte();
    if (b < 0)
      return -1;
    return b ^ 0x40;
  }
  return b;
}

/* ---- frame helpers ---- */

static int buf_zdle_encode(uint8_t *buf, int pos, uint8_t b) {
  if (b == ZDLE || b == 0x11 || b == 0x13 ||
      (b < 0x20 && b != 0x0a && b != 0x0d)) {
    buf[pos++] = ZDLE;
    buf[pos++] = b ^ 0x40;
  } else {
    buf[pos++] = b;
  }
  return pos;
}

static void send_header(uint8_t type, uint8_t f3, uint8_t f2, uint8_t f1,
                        uint8_t f0) {
  /* Buffer the entire header so it goes out in a single write(),
     preventing interleaved kernel log output from corrupting the frame. */
  uint8_t buf[32];
  int pos = 0;

  buf[pos++] = ZPAD;
  buf[pos++] = ZDLE;
  buf[pos++] = ZBIN;

  uint16_t crc = 0;
  uint8_t fields[5] = {type, f3, f2, f1, f0};
  for (int i = 0; i < 5; i++) {
    crc = crc16_ccitt_update(crc, fields[i]);
    pos = buf_zdle_encode(buf, pos, fields[i]);
  }

  pos = buf_zdle_encode(buf, pos, (crc >> 8) & 0xff);
  pos = buf_zdle_encode(buf, pos, crc & 0xff);

  write(STDOUT_FILENO, buf, pos);
}

static uint32_t header_offset(const uint8_t f[4]) {
  return ((uint32_t)f[0] << 24) | ((uint32_t)f[1] << 16) |
         ((uint32_t)f[2] << 8) | (uint32_t)f[3];
}

static void send_offset_header(uint8_t type, uint32_t offset) {
  send_header(type, (offset >> 24) & 0xff, (offset >> 16) & 0xff,
              (offset >> 8) & 0xff, offset & 0xff);
}

static int rewind_transfer(int fd, uint32_t offset) {
  if (lseek(fd, (off_t)offset, SEEK_SET) < 0)
    return -1;
  if (ftruncate(fd, (off_t)offset) < 0)
    return -1;
  return 0;
}

/* Receive a ZBIN header. Returns the frame type, fills f[4] with data bytes.
   Returns -1 on error. */
static int recv_header(uint8_t f[4]) {
  int scan_state = 0;

  for (;;) {
    int b = rx_byte();
    if (b < 0)
      return -1;

    if (scan_state == 0) {
      if (b == ZPAD)
        scan_state = 1;
      continue;
    }

    if (scan_state == 1) {
      if (b == ZPAD)
        continue;
      if (b == ZDLE) {
        scan_state = 2;
        continue;
      }
      scan_state = 0;
      continue;
    }

    if (b != ZBIN) {
      scan_state = (b == ZPAD) ? 1 : 0;
      continue;
    }

    /* Read type + 4 data bytes (all ZDLE-encoded) */
    int type = rx_zdle_byte();
    if (type < 0)
      return -1;

    uint16_t crc = crc16_ccitt_update(0, (uint8_t)type);
    bool malformed_header = false;
    for (int i = 0; i < 4; i++) {
      int v = rx_zdle_byte();
      if (v < 0) {
        malformed_header = true;
        break;
      }
      f[i] = (uint8_t)v;
      crc = crc16_ccitt_update(crc, f[i]);
    }
    if (malformed_header)
      continue;

    /* Read and verify CRC */
    int crc_hi = rx_zdle_byte();
    int crc_lo = rx_zdle_byte();
    if (crc_hi < 0 || crc_lo < 0)
      return -1;

    uint16_t recv_crc = ((uint16_t)crc_hi << 8) | (uint16_t)crc_lo;
    if (recv_crc != crc) {
      continue;
    }

    return type;
  }
}

/* Receive a data sub-packet. Data is written to buf (up to buf_size bytes).
   *out_len is set to the data length. *out_term is the terminator type.
   Returns 0 on success, -1 on error. */
static int recv_data_subpacket(uint8_t *buf, int buf_size, int *out_len,
                               uint8_t *out_term) {
  int len = 0;
  uint16_t crc = 0;

  for (;;) {
    int b = rx_byte();
    if (b < 0)
      return -1;

    if (b == ZDLE) {
      int next = rx_byte();
      if (next < 0)
        return -1;
      if (next == ZCRCE || next == ZCRCG || next == ZCRCQ || next == ZCRCW) {
        *out_term = (uint8_t)next;
        /* CRC covers data + terminator */
        crc = crc16_ccitt_update(crc, (uint8_t)next);
        break;
      }
      /* ZDLE-encoded data byte */
      uint8_t decoded = (uint8_t)(next ^ 0x40);
      crc = crc16_ccitt_update(crc, decoded);
      if (len < buf_size)
        buf[len++] = decoded;
      continue;
    }

    /* Regular data byte */
    crc = crc16_ccitt_update(crc, (uint8_t)b);
    if (len < buf_size)
      buf[len++] = b;
  }

  /* Read CRC-16 (two ZDLE-encoded bytes) */
  int crc_hi = rx_zdle_byte();
  int crc_lo = rx_zdle_byte();
  if (crc_hi < 0 || crc_lo < 0)
    return -1;

  uint16_t recv_crc = ((uint16_t)crc_hi << 8) | (uint16_t)crc_lo;
  if (recv_crc != crc) {
    return -1;
  }

  *out_len = len;
  return 0;
}

/* ---- public API ---- */

int zmodem_receive(const char *filename) {
  uint8_t f[4];
  uint8_t data_buf[ZMODEM_DATA_BUF_SIZE];
  int retries = 0;

  flush_stdin();

  /* Suppress kernel log output on the shared UART during the transfer
     to prevent interleaved bytes from corrupting Zmodem frames. */
  klog_ctl(0);

  /* 1. Send ZRINIT: f2 = CANFDX|ESCCTL, f1=f0=0 (no buffer limit) */
  send_header(ZRINIT, 0, CANFDX | ESCCTL, 0, 0);

  /* 2. Wait for ZFILE header */
  int type = recv_header(f);
  if (type != ZFILE) {
    return -1;
  }

  /* 3. Receive ZFILE data sub-packet (filename\0size\0...) */
  int data_len;
  uint8_t term;
  if (recv_data_subpacket(data_buf, sizeof(data_buf), &data_len, &term) < 0) {
    return -1;
  }
  /* Null-terminate for safe string ops */
  if (data_len < (int)sizeof(data_buf))
    data_buf[data_len] = '\0';

  /* Parse file info: first string is remote filename (ignore), second is size
   */
  char *info = (char *)data_buf;
  /* skip filename field */
  char *size_str = NULL;
  for (int i = 0; i < data_len; i++) {
    if (info[i] == '\0') {
      size_str = &info[i + 1];
      break;
    }
  }
  uint32_t expected_size = 0;
  if (size_str && size_str < (char *)data_buf + data_len)
    expected_size = (uint32_t)strtoul(size_str, NULL, 10);

  /* 4. Open output file */
  int fd = open(filename, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    send_header(ZFIN, 0, 0, 0, 0);
    return -1;
  }

  /* 5. Send ZRPOS(0) - start transfer from beginning */
  send_offset_header(ZRPOS, 0);

  /* 6. Receive ZDATA + data sub-packets */
  uint32_t total_received = 0;

  for (;;) {
    type = recv_header(f);
    if (type < 0) {
      retries++;
      if (retries > ZMODEM_MAX_RETRIES) {
        close(fd);
        return -1;
      }
      send_offset_header(ZRPOS, total_received);
      continue;
    }

    retries = 0;

    if (type == ZDATA) {
      uint32_t data_offset = header_offset(f);
      if (data_offset != total_received) {
        if (rewind_transfer(fd, data_offset) < 0) {
          close(fd);
          send_header(ZFIN, 0, 0, 0, 0);
          return -1;
        }
        total_received = data_offset;
      }

      /* Receive data sub-packets until ZCRCW or end */
      bool restart_transfer = false;
      for (;;) {
        if (recv_data_subpacket(data_buf, sizeof(data_buf), &data_len, &term) <
            0) {
          retries++;
          if (retries > ZMODEM_MAX_RETRIES) {
            close(fd);
            return -1;
          }
          if (rewind_transfer(fd, total_received) < 0) {
            close(fd);
            return -1;
          }
          /* Do NOT flush stdin here.  The host may have already sent a
             retry ZDATA frame whose bytes are sitting in the UART receive
             buffer.  recv_header() in the outer loop will scan past any
             remaining garbage from the corrupted sub-packet and find the
             valid frame header. */
          send_offset_header(ZRPOS, total_received);
          restart_transfer = true;
          break;
        }

        total_received += data_len;
        retries = 0;

        /* Write BEFORE sending ZACK.  Flash erase/program disables
           interrupts on RP2350 (shared SPI bus), so bytes arriving
           during the write overflow the 32-byte HW FIFO.  Sending
           ZACK after the write ensures the host waits and the UART
           is ready to receive the next chunk. */
        write(fd, data_buf, data_len);

        send_offset_header(ZACK, total_received);

        if (term == ZCRCW || term == ZCRCE) {
          break;
        }
      }
      if (restart_transfer)
        continue;
    } else if (type == ZEOF) {
      /* f3..f0 = file offset */
      uint32_t eof_offset = header_offset(f);

      if (eof_offset != total_received) {
        retries++;
        if (retries > ZMODEM_MAX_RETRIES) {
          close(fd);
          send_header(ZFIN, 0, 0, 0, 0);
          return -1;
        }
        send_offset_header(ZRPOS, total_received);
        continue;
      }

      close(fd);

      fprintf(stderr, "OK %u\n", total_received);

      /* 7. Send ZFIN */
      send_header(ZFIN, 0, 0, 0, 0);

      /* 8. Wait for sender's ZFIN */
      type = recv_header(f);
      if (type != ZFIN) {
        return -1;
      }

      return 0;
    } else if (type == ZFIN) {
      close(fd);
      send_header(ZFIN, 0, 0, 0, 0);
      return -1;
    } else {
      retries++;
      if (retries > ZMODEM_MAX_RETRIES) {
        close(fd);
        send_header(ZFIN, 0, 0, 0, 0);
        return -1;
      }
      send_offset_header(ZRPOS, total_received);
    }
  }
}
