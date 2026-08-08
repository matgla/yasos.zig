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

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../crc16.h"
#include "../terminal.h"

#include <sys/klog.h>

#define ZMODEM_DATA_BUF_SIZE 1024
#define ZMODEM_MAX_RETRIES 5
#define ZMODEM_PATH_MAX 256

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

/* Diagnostics for the transfer-failure paths: remember how the last
   rx_byte failed so the error paths can report it on stderr. */
static int rzdbg_last_rc;
static int rzdbg_last_errno;

/* A syscall per byte cannot keep up with the sender. At 921600 baud a byte
   lands every 10.9 us, and the read() plus the per-byte CRC work costs more
   than that, so the kernel's 512-byte UART ring (RingBuffer(u8, 512) in the
   RP2350 HAL) fills and bytes are lost in the middle of a sub-packet. That is
   exactly what the "crc mismatch len=<short of 1024>" failures were: the
   terminator still arrived, but dozens of data bytes in front of it did not.

   Taking whatever has arrived in one read amortises the syscall over the whole
   burst, and the deeper we fall behind the more each read recovers. The tty is
   in raw mode with VMIN=1 (see prepare_terminal), and the kernel's uart_file
   read returns as soon as it has that many bytes, so a large read never waits
   to fill the buffer. */
#define ZMODEM_RX_BUF_SIZE 2048
static uint8_t rx_buf[ZMODEM_RX_BUF_SIZE];
static int rx_buf_pos;
static int rx_buf_len;

/* Drop what we have already pulled out of the kernel, so a flush_stdin() means
   what it says: our buffer is as much "already received" as the tty's is. */
static void rx_discard_buffered(void) {
  rx_buf_pos = 0;
  rx_buf_len = 0;
}

/* Read one raw byte. Returns -1 on timeout/error. */
static int rx_byte(void) {
  if (rx_buf_pos >= rx_buf_len) {
    errno = 0;
    int rc = read(STDIN_FILENO, rx_buf, sizeof(rx_buf));
    if (rc <= 0) {
      rzdbg_last_rc = rc;
      rzdbg_last_errno = errno;
      return -1;
    }
    rx_buf_pos = 0;
    rx_buf_len = rc;
  }
  return rx_buf[rx_buf_pos++];
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
  errno = 0;
  if (lseek(fd, (off_t)offset, SEEK_SET) < 0) {
    fprintf(stderr, "RZDBG rewind lseek(%u) failed errno=%d\n", offset, errno);
    return -1;
  }
  errno = 0;
  if (ftruncate(fd, (off_t)offset) < 0) {
    fprintf(stderr, "RZDBG rewind ftruncate(%u) failed errno=%d\n", offset,
            errno);
    return -1;
  }
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
static const char *rzdbg_reason = "";
static int rzdbg_len;

/* Format the kernel's console receive-loss counters into *out*.
 *
 * A sub-packet CRC failure on its own cannot say where the missing bytes went,
 * and the three possibilities have nothing to do with each other: an overrun
 * means the UART's 32-byte hardware FIFO filled while the receive interrupt was
 * masked, a drop means the ring above it filled because nothing read it fast
 * enough, and neither means the bytes never arrived and the fault is upstream
 * of this machine entirely. So the answer is attached to every failure rather
 * than reported once at the end -- a batch of several thousand files runs for
 * far too long to wait for, and in practice gets interrupted first.
 *
 * Leaves *out* empty on a kernel without /proc/uart, which is also what the
 * host build of this receiver sees.
 */
static void read_rx_losses(char *out, size_t out_size) {
  out[0] = '\0';

  int fd = open("/proc/uart", O_RDONLY);
  if (fd < 0)
    return;
  char raw[288];
  int length = (int)read(fd, raw, sizeof(raw) - 1);
  close(fd);
  if (length <= 0)
    return;
  raw[length] = '\0';

  /* Longest key first where one is a prefix of another, so strstr cannot match
     the short name inside the long one. */
  static const char *const keys[] = {"rx_bytes",           "rx_overruns",
                                     "rx_dropped",         "rx_fifo_full",
                                     "rx_framing_errors",  "max_overrun_gap_us",
                                     "max_late_gap_us"};
  enum { KEY_COUNT = sizeof(keys) / sizeof(keys[0]) };
  unsigned long values[KEY_COUNT] = {0};
  for (int i = 0; i < KEY_COUNT; ++i) {
    const char *found = strstr(raw, keys[i]);
    if (found != NULL)
      values[i] = strtoul(found + strlen(keys[i]), NULL, 10);
  }

  snprintf(out, out_size,
           " rx=%lu ovr=%lu drop=%lu full=%lu fe=%lu ogap=%luus lgap=%luus",
           values[0], values[1], values[2], values[3], values[4], values[5],
           values[6]);
}

static int recv_data_subpacket(uint8_t *buf, int buf_size, int *out_len,
                               uint8_t *out_term) {
  int len = 0;
  uint16_t crc = 0;

  for (;;) {
    int b = rx_byte();
    if (b < 0) {
      rzdbg_reason = "data byte rx";
      rzdbg_len = len;
      return -1;
    }

    if (b == ZDLE) {
      int next = rx_byte();
      if (next < 0) {
        rzdbg_reason = "post-ZDLE rx";
        rzdbg_len = len;
        return -1;
      }
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
  if (crc_hi < 0 || crc_lo < 0) {
    rzdbg_reason = "crc rx";
    rzdbg_len = len;
    return -1;
  }

  uint16_t recv_crc = ((uint16_t)crc_hi << 8) | (uint16_t)crc_lo;
  if (recv_crc != crc) {
    rzdbg_reason = "crc mismatch";
    rzdbg_len = len;
    return -1;
  }

  *out_len = len;
  return 0;
}

/* Create every missing directory along the path leading to *path*.
   Failures are deliberately ignored: mkdir on an existing directory is the
   common case, and a directory that genuinely cannot be created shows up as a
   failing open() a moment later, with one clear error instead of two. */
static void ensure_parent_dirs(char *path) {
  for (char *p = path + 1; *p != '\0'; ++p) {
    if (*p != '/')
      continue;
    *p = '\0';
    mkdir(path, 0755);
    *p = '/';
  }
}

/* Everything up to and including the last '/', which is what two paths must
   share for the second one to skip the mkdir walk. */
static int parent_dir_length(const char *path) {
  int last_slash = 0;
  for (int i = 0; path[i] != '\0'; ++i) {
    if (path[i] == '/')
      last_slash = i;
  }
  return last_slash;
}

/* Receive one file body: ZDATA sub-packets into *fd* until the sender's ZEOF
   agrees with what we wrote. Returns 0 with *out_received* set, or -1 when the
   retry budget ran out (the caller closes the file and ends the session). */
static int receive_file_body(int fd, uint32_t *out_received) {
  uint8_t f[4];
  uint8_t data_buf[ZMODEM_DATA_BUF_SIZE];
  int data_len;
  uint8_t term;
  int retries = 0;
  uint32_t total_received = 0;
  int type;

  for (;;) {
    type = recv_header(f);
    if (type < 0) {
      retries++;
      if (retries > ZMODEM_MAX_RETRIES) {
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
          return -1;
        }
        total_received = data_offset;
      }

      /* Receive data sub-packets until ZCRCW or end */
      bool restart_transfer = false;
      for (;;) {
        if (recv_data_subpacket(data_buf, sizeof(data_buf), &data_len, &term) <
            0) {
          char losses[128];
          read_rx_losses(losses, sizeof(losses));
          fprintf(stderr,
                  "\nRZDBG subpacket fail: %s len=%d rc=%d errno=%d total=%u "
                  "retry=%d%s\n",
                  rzdbg_reason, rzdbg_len, rzdbg_last_rc, rzdbg_last_errno,
                  total_received, retries + 1, losses);
          retries++;
          if (retries > ZMODEM_MAX_RETRIES) {
            fprintf(stderr, "RZDBG giving up: max retries\n");
            return -1;
          }
          if (rewind_transfer(fd, total_received) < 0) {
            fprintf(stderr, "RZDBG giving up: rewind failed\n");
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
          return -1;
        }
        send_offset_header(ZRPOS, total_received);
        continue;
      }

      *out_received = total_received;
      return 0;
    } else if (type == ZFIN) {
      /* The sender gave up mid-file. */
      return -1;
    } else {
      retries++;
      if (retries > ZMODEM_MAX_RETRIES) {
        return -1;
      }
      send_offset_header(ZRPOS, total_received);
    }
  }
}

/* ---- public API ---- */

/* One receive session.
 *
 * With *fixed_filename* the session carries a single file, whose name comes
 * from the command line and whose ZFILE name field is ignored -- the shape the
 * harness has always used. With NULL it is a batch: every file names itself in
 * its ZFILE header, and the session runs until the sender says ZFIN.
 *
 * Batch matters because the alternative for the smoke suite's 4546 sources is
 * 4546 separate `rz` invocations, where the process spawn and handshake cost
 * far more than the ~1 KiB of source they each carry.
 */
static int zmodem_session(const char *fixed_filename) {
  const bool batch = (fixed_filename == NULL);
  uint8_t f[4];
  uint8_t data_buf[ZMODEM_DATA_BUF_SIZE];
  char path[ZMODEM_PATH_MAX];
  char prepared_dir[ZMODEM_PATH_MAX];
  int prepared_dir_length = -1;
  uint32_t files_received = 0;
  uint32_t bytes_received = 0;

  flush_stdin();
  rx_discard_buffered();

  /* Suppress kernel log output on the shared UART during the transfer
     to prevent interleaved bytes from corrupting Zmodem frames. */
  klog_ctl(0);

  /* 1. Send ZRINIT: f2 = CANFDX|ESCCTL, f1=f0=0 (no buffer limit) */
  send_header(ZRINIT, 0, CANFDX | ESCCTL, 0, 0);

  int between_files_retries = 0;
  for (;;) {
    /* 2. Wait for ZFILE (another file) or ZFIN (the batch is done) */
    int type = recv_header(f);
    if (type == ZFIN) {
      send_header(ZFIN, 0, 0, 0, 0);
      if (!batch)
        return -1; /* the sender quit before sending the one file we wanted */
      fprintf(stderr, "OK %u files %u bytes\n", files_received, bytes_received);
      return 0;
    }
    if (type != ZFILE) {
      /* Between files the only thing we owe the sender is the ZRINIT that
         invites the next one, so anything else here -- silence, or the ZEOF it
         re-sends when that ZRINIT went missing -- is answered by saying it
         again. Losing one frame should not cost the remaining files in a batch
         of several thousand. */
      if (!batch || ++between_files_retries > ZMODEM_MAX_RETRIES) {
        return -1;
      }
      send_header(ZRINIT, 0, CANFDX | ESCCTL, 0, 0);
      continue;
    }
    between_files_retries = 0;

    /* 3. Receive ZFILE data sub-packet (filename\0size\0...) */
    int data_len;
    uint8_t term;
    if (recv_data_subpacket(data_buf, sizeof(data_buf), &data_len, &term) < 0) {
      return -1;
    }
    /* Null-terminate for safe string ops */
    if (data_len < (int)sizeof(data_buf))
      data_buf[data_len] = '\0';

    const char *target = fixed_filename;
    if (batch) {
      /* The name field is the whole point in batch mode. Absolute paths only:
         the sender addresses the target's filesystem, and a relative name
         would land wherever the shell happened to leave us. */
      const char *name = (const char *)data_buf;
      int name_length = (int)strnlen(name, sizeof(path));
      if (name[0] != '/' || name_length >= (int)sizeof(path)) {
        fprintf(stderr, "ERROR: bad path in batch\n");
        send_header(ZFIN, 0, 0, 0, 0);
        return -1;
      }
      memcpy(path, name, (size_t)name_length + 1);

      /* The sender walks its list in sorted order, so runs of files share a
         directory; re-walking it for each one would be thousands of pointless
         mkdir syscalls on the SD card. */
      int dir_length = parent_dir_length(path);
      if (dir_length != prepared_dir_length ||
          memcmp(path, prepared_dir, (size_t)dir_length) != 0) {
        ensure_parent_dirs(path);
        memcpy(prepared_dir, path, (size_t)dir_length);
        prepared_dir_length = dir_length;
      }
      target = path;
    }

    /* 4. Open output file */
    int fd = open(target, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
      fprintf(stderr, "ERROR: cannot open %s\n", target);
      send_header(ZFIN, 0, 0, 0, 0);
      return -1;
    }

    /* 5. Send ZRPOS(0) - start transfer from beginning */
    send_offset_header(ZRPOS, 0);

    /* 6. Receive ZDATA + data sub-packets until ZEOF */
    uint32_t received = 0;
    int rc = receive_file_body(fd, &received);
    close(fd);
    if (rc < 0) {
      send_header(ZFIN, 0, 0, 0, 0);
      return -1;
    }

    files_received++;
    bytes_received += received;

    if (!batch) {
      fprintf(stderr, "OK %u\n", received);
      /* 7. Send ZFIN, 8. wait for the sender's ZFIN */
      send_header(ZFIN, 0, 0, 0, 0);
      return recv_header(f) == ZFIN ? 0 : -1;
    }

    /* Batch: invite the next file. Deliberately silent per file -- 4546 "OK"
       lines would be a couple of hundred KiB of extra traffic on the same
       UART the transfer is using. */
    send_header(ZRINIT, 0, CANFDX | ESCCTL, 0, 0);
  }
}

int zmodem_receive(const char *filename) {
  return zmodem_session(filename);
}

int zmodem_receive_batch(void) {
  return zmodem_session(NULL);
}
