/**
 * main.c
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation, either version
 * 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be
 * useful, but WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General
 * Public License along with this program. If not, see
 * <https://www.gnu.org/licenses/>.
 */

/*
 * File transfer receiver.
 *
 * Supports two protocols:
 *
 * 1. Simple chunked protocol (default):
 *   1. Host runs: rz <filename>
 *   2. Target prints "READY\n" on stderr
 *   3. Host sends 4-byte file size (little-endian uint32)
 *   4. Host streams file data in CHUNK_SIZE byte chunks
 *   5. Target sends ACK (0x06) after each chunk for flow control
 *   6. Host sends 4-byte CRC32 (little-endian uint32)
 *   7. Target verifies CRC, prints "OK <size>\n" or "ERROR: ...\n" on stderr
 *
 * 2. Zmodem protocol (--zmodem):
 *   Standard Zmodem receive using ZBIN frames with CRC-16.
 */

#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "crc32.h"
#include "terminal.h"
#include "zmodem/zmodem.h"

#include <sys/klog.h>

#define CHUNK_SIZE 4096
#define ACK 0x06

static int read_exact(uint8_t *buf, size_t count) {
  size_t total = 0;
  while (total < count) {
    int rc = read(STDIN_FILENO, buf + total, count - total);
    if (rc <= 0)
      return -1;
    total += rc;
  }
  return 0;
}

static uint32_t read_le32(const uint8_t *buf) {
  return (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) | ((uint32_t)buf[2] << 16) |
         ((uint32_t)buf[3] << 24);
}

static void send_ack(void) {
  uint8_t ack = ACK;
  write(STDOUT_FILENO, &ack, 1);
}

static int receive_chunked(const char *filename) {
  prepare_terminal();
  flush_stdin();

  fprintf(stderr, "READY\n");

  /* Read 4-byte file size (little-endian) */
  uint8_t hdr[4];
  if (read_exact(hdr, 4) < 0) {
    fprintf(stderr, "ERROR: failed to read file size\n");
    restore_terminal();
    return 1;
  }
  uint32_t filesize = read_le32(hdr);

  int fd = open(filename, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    fprintf(stderr, "ERROR: cannot open %s\n", filename);
    restore_terminal();
    return 1;
  }

  uint8_t chunk[CHUNK_SIZE];
  uint32_t remaining = filesize;
  uint32_t file_crc = 0;

  while (remaining > 0) {
    uint32_t to_read = remaining > CHUNK_SIZE ? CHUNK_SIZE : remaining;
    if (read_exact(chunk, to_read) < 0) {
      fprintf(stderr, "ERROR: read failed at offset %u\n",
              filesize - remaining);
      close(fd);
      restore_terminal();
      return 1;
    }

    write(fd, chunk, to_read);
    file_crc = crc32(file_crc, chunk, to_read);
    remaining -= to_read;

    send_ack();
  }

  close(fd);

  /* Read expected CRC32 (4 bytes, little-endian) */
  uint8_t crc_buf[4];
  if (read_exact(crc_buf, 4) < 0) {
    fprintf(stderr, "ERROR: failed to read CRC\n");
    restore_terminal();
    return 1;
  }

  uint32_t expected_crc = read_le32(crc_buf);

  if (file_crc != expected_crc) {
    fprintf(stderr, "ERROR: CRC mismatch (got %08x, expected %08x)\n", file_crc,
            expected_crc);
    restore_terminal();
    return 1;
  }

  fprintf(stderr, "OK %u\n", filesize);
  restore_terminal();
  return 0;
}

static int receive_zmodem(const char *filename) {
  prepare_terminal();
  int rc = filename != NULL ? zmodem_receive(filename) : zmodem_receive_batch();
  klog_ctl(1);
  restore_terminal();
  return rc < 0 ? 1 : 0;
}

static bool starts_with(const char *arg, const char *prefix) {
  return strcmp(arg, prefix) == 0;
}

int main(int argc, char *argv[]) {
  bool use_zmodem = false;
  bool batch = false;
  const char *filename = NULL;

  for (int i = 1; i < argc; i++) {
    if (starts_with(argv[i], "--zmodem")) {
      use_zmodem = true;
    } else if (starts_with(argv[i], "--batch")) {
      /* Every file names itself, so there is no filename argument. */
      use_zmodem = true;
      batch = true;
    } else {
      filename = argv[i];
    }
  }

  if (batch) {
    return receive_zmodem(NULL);
  }

  if (filename == NULL) {
    fprintf(stderr, "Usage: rz [--zmodem] <filename>\n");
    fprintf(stderr, "       rz --batch\n");
    return 1;
  }

  if (use_zmodem) {
    return receive_zmodem(filename);
  }
  return receive_chunked(filename);
}
