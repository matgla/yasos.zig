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

#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include "zmodem/frame.h"

// ZMODEM Protocol Constants
#define ZPAD 0x2A   // '*' Padding character
#define ZDLE 0x18   // Ctrl-X ZDLE escape character
#define XON 0x11    // Ctrl-Q
#define XOFF 0x13   // Ctrl-S
#define ZMAXHLEN 16 // Max header length

// Escape sequences
#define ZDLEE (ZDLE ^ 0x40)

// Data subpacket frame end types
#define ZCRCE 0x68 // CRC next, frame ends, header follows
#define ZCRCG 0x69 // CRC next, frame continues non-stop
#define ZCRCQ 0x6A // CRC next, frame continues, ZACK expected
#define ZCRCW 0x6B // CRC next, ZACK expected, end of frame

typedef struct {
  ZFrameType type;
  ZFrameEncoding encoding;
  unsigned char flags[4];
  unsigned char *data;
  size_t length;
  unsigned int crc;
} ZFrame;

typedef enum {
  ZRECV_INIT,
  ZRECV_WAIT_ZPAD,
  ZRECV_WAIT_ZDLE,
  ZRECV_WAIT_HEADER_TYPE,
  ZRECV_WAIT_FRAME_TYPE,
  ZRECV_WAIT_FLAGS,
  ZRECV_WAIT_DATA,
  ZRECV_WAIT_CRC,
  ZRECV_DONE,
  ZRECV_ERROR
} ZReceiveState;

typedef enum {
  STATUS_OK,
  STATUS_ERROR,
  STATUS_TIMEOUT,
  STATUS_CRC_ERROR,
  STATUS_DONE
} ZReceiveStatus;

static ZReceiveState receive_state = ZRECV_INIT;
static int file_fd = -1;
static char current_filename[256];
static size_t bytes_received = 0;

// CRC-16 calculation
static unsigned short crc16_update(unsigned short crc, unsigned char data) {
  crc = crc ^ ((unsigned short)data << 8);
  for (int i = 0; i < 8; i++) {
    if (crc & 0x8000) {
      crc = (crc << 1) ^ 0x1021;
    } else {
      crc = crc << 1;
    }
  }
  return crc;
}

static unsigned short crc16(const unsigned char *data, size_t len) {
  unsigned short crc = 0;
  for (size_t i = 0; i < len; i++) {
    crc = crc16_update(crc, data[i]);
  }
  return crc;
}

// Read with timeout
static int read_byte_timeout(unsigned char *byte, int timeout_ms) {
  // fd_set readfds;
  // struct timeval timeout;

  // FD_ZERO(&readfds);
  // FD_SET(STDIN_FILENO, &readfds);

  // timeout.tv_sec = timeout_ms / 1000;
  // timeout.tv_usec = (timeout_ms % 1000) * 1000;

  // int ret = select(STDIN_FILENO + 1, &readfds, NULL, NULL, &timeout);
  // if (ret <= 0) {
  // return STATUS_TIMEOUT;
  // }

  if (read(STDIN_FILENO, byte, 1) != 1) {
    return STATUS_ERROR;
  }

  return STATUS_OK;
}

// Decode ZDLE escaped byte
static int decode_byte(unsigned char c, unsigned char *decoded) {
  if (c == ZDLE) {
    return -1; // Need next byte
  }

  if ((c & 0x60) == 0x40) {
    *decoded = c ^ 0x40;
    return 0;
  }

  *decoded = c;
  return 0;
}

// Send ZMODEM header
static void send_hex_header(ZFrameType type, const unsigned char flags[4]) {
  unsigned char header[7];
  header[0] = type;
  memcpy(&header[1], flags, 4);

  unsigned short crc = crc16(header, 5);
  header[5] = (crc >> 8) & 0xFF;
  header[6] = crc & 0xFF;

  // fprintf(stderr, "Sending hex header: ");
  for (int i = 0; i < 7; i++) {
    // fprintf(stderr, "%02X,", header[i]);
  }
  // fprintf(stderr, "\n");

  // Write ZPAD ZPAD ZDLE ZHEX
  unsigned char prefix[4] = {ZPAD, ZPAD, ZDLE, ZHEX};
  write(STDOUT_FILENO, prefix, 4);

  // Write header as hex (14 ASCII characters)
  for (int i = 0; i < 7; i++) {
    char hex[3];
    snprintf(hex, sizeof(hex), "%02x", header[i]); // Use lowercase hex
    write(STDOUT_FILENO, hex, 2);
  }

  // Write CR LF XON
  unsigned char suffix[3] = {0x0D, 0x0A, XON};
  write(STDOUT_FILENO, suffix, 3);

  // Flush output to ensure sz receives it immediately
  fsync(STDOUT_FILENO);
}

// Send ZRINIT - Receiver initialization
static void send_zrinit() {
  unsigned char flags[4] = {0, 0, 0, 0};
  // flags[0] = CANFDX | CANOVIO; // Add basic capabilities
  send_hex_header(ZRINIT, flags);
}

// Send ZACK - Acknowledgment
static void send_zack(unsigned int pos) {
  unsigned char flags[4];
  flags[0] = pos & 0xFF;
  flags[1] = (pos >> 8) & 0xFF;
  flags[2] = (pos >> 16) & 0xFF;
  flags[3] = (pos >> 24) & 0xFF;
  send_hex_header(ZACK, flags);
}

// Send ZFIN - Finish session
static void send_zfin() {
  unsigned char flags[4] = {0, 0, 0, 0};
  send_hex_header(ZFIN, flags);
}

// Send ZRPOS - Resume data at this position
static void send_zrpos(unsigned int pos) {
  unsigned char flags[4];
  flags[0] = pos & 0xFF;
  flags[1] = (pos >> 8) & 0xFF;
  flags[2] = (pos >> 16) & 0xFF;
  flags[3] = (pos >> 24) & 0xFF;
  send_hex_header(ZRPOS, flags);
}

// Receive ZMODEM frame
static ZReceiveStatus receive_frame(ZFrame *frame) {
  static unsigned char buffer[8192];
  static size_t buffer_pos = 0;
  static bool escape_next = false;

  while (true) {
    unsigned char c;
    int status = read_byte_timeout(&c, 10000);

    if (status == STATUS_TIMEOUT) {
      return STATUS_TIMEOUT;
    }
    if (status != STATUS_OK) {
      return STATUS_ERROR;
    }

    switch (receive_state) {
    case ZRECV_INIT:
    case ZRECV_WAIT_ZPAD:
      if (c == ZPAD) {
        receive_state = ZRECV_WAIT_ZDLE;
      }
      break;

    case ZRECV_WAIT_ZDLE:
      if (c == ZDLE) {
        receive_state = ZRECV_WAIT_HEADER_TYPE;
      } else if (c == ZPAD) {
        // Stay in ZRECV_WAIT_ZDLE, multiple ZPADs are allowed
      } else {
        receive_state = ZRECV_WAIT_ZPAD;
      }
      break;

    case ZRECV_WAIT_HEADER_TYPE:
      if (c == ZHEX) {
        frame->encoding = ZHEX;
        receive_state = ZRECV_WAIT_FRAME_TYPE;
        buffer_pos = 0;
        escape_next = false;
      } else if (c == ZBIN) {
        frame->encoding = ZBIN;
        receive_state = ZRECV_WAIT_FRAME_TYPE;
        buffer_pos = 0;
        escape_next = false;
      } else if (c == ZBIN32) {
        frame->encoding = ZBIN32;
        receive_state = ZRECV_WAIT_FRAME_TYPE;
        buffer_pos = 0;
        escape_next = false;
      } else {
        receive_state = ZRECV_WAIT_ZPAD;
      }
      break;

    case ZRECV_WAIT_FRAME_TYPE:
      if (frame->encoding == ZHEX) {
        // Skip CR and LF if present
        if (c == 0x0D || c == 0x0A || c == XON || c == 0x8D || c == 0x8A) {
          continue;
        }

        // Read hex encoded header (14 chars)
        buffer[buffer_pos++] = c;
        if (buffer_pos >= 14) {
          // Convert hex to binary
          unsigned char header[7];
          for (int i = 0; i < 7; i++) {
            char hex[3] = {buffer[i * 2], buffer[i * 2 + 1], 0};
            header[i] = strtoul(hex, NULL, 16);
          }

          frame->type = header[0];
          memcpy(frame->flags, &header[1], 4);

          // Verify CRC
          // fprintf(stderr, "zhex: ");
          for (int i = 0; i < 7; i++) {
            // fprintf(stderr, "%02X,", header[i]);
          }
          // fprintf(stderr, "\n");
          unsigned short calc_crc = crc16(header, 5);
          // fprintf(stderr, "Calculated CRC: %04X\n", calc_crc);
          unsigned short recv_crc = (header[5] << 8) | header[6];

          if (calc_crc == recv_crc) {
            receive_state = ZRECV_DONE;
            buffer_pos = 0;
            return STATUS_OK;
          } else {
            fprintf(stderr, "CRC mismatch: calculated %04X, received %04X\n",
                    calc_crc, recv_crc);
            receive_state = ZRECV_WAIT_ZPAD;
            buffer_pos = 0;
            return STATUS_CRC_ERROR;
          }
        }
      } else if (frame->encoding == ZBIN) {
        // Binary encoding with CRC-16
        // Need to handle ZDLE escaping
        if (escape_next) {
          // Unescape the character
          if ((c & 0x60) == 0x40) {
            buffer[buffer_pos++] = c ^ 0x40;
          } else {
            buffer[buffer_pos++] = c;
          }
          escape_next = false;
        } else if (c == ZDLE) {
          escape_next = true;
        } else {
          buffer[buffer_pos++] = c;
        }

        // ZBIN header: 5 bytes (type + 4 flags) + 2 bytes CRC = 7 bytes
        if (buffer_pos >= 7) {
          frame->type = buffer[0];
          memcpy(frame->flags, &buffer[1], 4);

          // fprintf(stderr, "zbin: ");
          for (int i = 0; i < 7; i++) {
            // fprintf(stderr, "%02X,", buffer[i]);
          }
          // fprintf(stderr, "\n");
          // Verify CRC-16
          unsigned short calc_crc = crc16(buffer, 5);
          unsigned short recv_crc = (buffer[5] << 8) | buffer[6];

          if (calc_crc == recv_crc) {
            receive_state = ZRECV_DONE;
            buffer_pos = 0;
            escape_next = false;
            return STATUS_OK;
          } else {
            fprintf(stderr,
                    "ZBIN CRC mismatch: calculated %04X, received %04X\n",
                    calc_crc, recv_crc);
            receive_state = ZRECV_WAIT_ZPAD;
            buffer_pos = 0;
            escape_next = false;
            return STATUS_CRC_ERROR;
          }
        }
      } else if (frame->encoding == ZBIN32) {
        // Binary encoding with CRC-32
        // Need to handle ZDLE escaping
        if (escape_next) {
          // Unescape the character
          if ((c & 0x60) == 0x40) {
            buffer[buffer_pos++] = c ^ 0x40;
          } else {
            buffer[buffer_pos++] = c;
          }
          escape_next = false;
        } else if (c == ZDLE) {
          escape_next = true;
        } else {
          buffer[buffer_pos++] = c;
        }

        // ZBIN32 header: 5 bytes (type + 4 flags) + 4 bytes CRC = 9 bytes
        if (buffer_pos >= 9) {
          frame->type = buffer[0];
          memcpy(frame->flags, &buffer[1], 4);

          // Verify CRC-32 (little-endian)
          unsigned int calc_crc = crc32(buffer, 5);
          unsigned int recv_crc = buffer[5] | (buffer[6] << 8) |
                                  (buffer[7] << 16) | (buffer[8] << 24);

          if (calc_crc == recv_crc) {
            receive_state = ZRECV_DONE;
            buffer_pos = 0;
            escape_next = false;
            return STATUS_OK;
          } else {
            fprintf(stderr,
                    "ZBIN32 CRC mismatch: calculated %08X, received %08X\n",
                    calc_crc, recv_crc);
            receive_state = ZRECV_WAIT_ZPAD;
            buffer_pos = 0;
            escape_next = false;
            return STATUS_CRC_ERROR;
          }
        }
      }
      break;

    case ZRECV_DONE:
      return STATUS_OK;

    default:
      receive_state = ZRECV_WAIT_ZPAD;
      break;
    }
  }
}

// Handle ZFILE frame (file information)
static void handle_zfile(ZFrame *frame) {
  // Read file data subpacket (filename and metadata)
  unsigned char filename_buf[256];
  size_t filename_len = 0;
  bool escape_next = false;
  unsigned char frame_end = 0;

  // fprintf(stderr, "Receiving ZFILE frame...\n");

  while (filename_len < sizeof(filename_buf) - 1) {
    unsigned char c;
    if (read_byte_timeout(&c, 5000) != STATUS_OK) {
      fprintf(stderr, "Timeout reading filename\n");
      break;
    }

    if (escape_next) {
      // Check for frame end markers
      if (c == ZCRCE || c == ZCRCG || c == ZCRCQ || c == ZCRCW) {
        frame_end = c;

        // Read CRC-16 (2 bytes, may be escaped)
        unsigned char crc_bytes[2];
        int crc_idx = 0;
        bool crc_escape = false;

        while (crc_idx < 2) {
          unsigned char crc_c;
          if (read_byte_timeout(&crc_c, 5000) != STATUS_OK) {
            fprintf(stderr, "Timeout reading CRC\n");
            return;
          }

          if (crc_escape) {
            if ((crc_c & 0x60) == 0x40) {
              crc_bytes[crc_idx++] = crc_c ^ 0x40;
            } else {
              crc_bytes[crc_idx++] = crc_c;
            }
            crc_escape = false;
          } else if (crc_c == ZDLE) {
            crc_escape = true;
          } else {
            crc_bytes[crc_idx++] = crc_c;
          }
        }

        // Verify CRC
        unsigned short calc_crc = crc16(filename_buf, filename_len);
        calc_crc = crc16_update(calc_crc, frame_end);
        unsigned short recv_crc = (crc_bytes[0] << 8) | crc_bytes[1];

        if (calc_crc != recv_crc) {
          fprintf(stderr,
                  "Filename CRC mismatch: calculated %04X, received %04X\n",
                  calc_crc, recv_crc);
          return;
        }

        break;
      }

      // Normal escaped character
      if ((c & 0x60) == 0x40) {
        filename_buf[filename_len++] = c ^ 0x40;
      } else {
        filename_buf[filename_len++] = c;
      }
      escape_next = false;
    } else if (c == ZDLE) {
      escape_next = true;
    } else {
      if (c == 0) {
        // Null terminator - end of filename
        break;
      }
      filename_buf[filename_len++] = c;
    }
  }

  filename_buf[filename_len] = 0;

  // Parse filename (format: "filename\0size mtime mode serial_number")
  // For now, just extract the filename
  strncpy(current_filename, (char *)filename_buf, sizeof(current_filename) - 1);
  current_filename[sizeof(current_filename) - 1] = 0;

  // fprintf(stderr, "Receiving file: %s\n", current_filename);

  // Close previous file if open
  if (file_fd >= 0) {
    close(file_fd);
  }

  // Open file for writing
  file_fd = open(current_filename, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (file_fd < 0) {
    fprintf(stderr, "Error opening file: %s\n", current_filename);
    // Send ZSKIP to skip this file
    unsigned char flags[4] = {0, 0, 0, 0};
    send_hex_header(ZSKIP, flags);
    return;
  }

  // Send ZRPOS - ready to receive at position 0
  // fprintf(stderr, "Sending ZRPOS (position 0)\n");
  send_zrpos(0);
}

// Handle ZDATA frame (receive data packets)
static ZReceiveStatus handle_zdata(ZFrame *frame) {
  // Extract file position from flags
  unsigned int file_pos = frame->flags[0] | (frame->flags[1] << 8) |
                          (frame->flags[2] << 16) | (frame->flags[3] << 24);

  // fprintf(stderr, "ZDATA at position %u\n", file_pos);

  // Seek to position if needed
  if (file_fd >= 0 && lseek(file_fd, file_pos, SEEK_SET) < 0) {
    fprintf(stderr, "Error seeking to position %u\n", file_pos);
    return STATUS_ERROR;
  }

  // Receive data subpackets
  unsigned char data_buffer[8192];
  size_t data_pos = 0;
  bool escape_next = false;
  unsigned char frame_end = 0;

  while (true) {
    unsigned char c;
    int status = read_byte_timeout(&c, 10000);

    if (status == STATUS_TIMEOUT) {
      fprintf(stderr, "Timeout receiving data\n");
      return STATUS_TIMEOUT;
    }
    if (status != STATUS_OK) {
      return STATUS_ERROR;
    }

    if (escape_next) {
      // Check for frame end markers
      if (c == ZCRCE || c == ZCRCG || c == ZCRCQ || c == ZCRCW) {
        frame_end = c;

        // Read CRC-16 (2 bytes, may be escaped)
        unsigned char crc_bytes[2];
        int crc_idx = 0;
        bool crc_escape = false;

        while (crc_idx < 2) {
          unsigned char crc_c;
          if (read_byte_timeout(&crc_c, 5000) != STATUS_OK) {
            return STATUS_ERROR;
          }

          if (crc_escape) {
            if ((crc_c & 0x60) == 0x40) {
              crc_bytes[crc_idx++] = crc_c ^ 0x40;
            } else {
              crc_bytes[crc_idx++] = crc_c;
            }
            crc_escape = false;
          } else if (crc_c == ZDLE) {
            crc_escape = true;
          } else {
            crc_bytes[crc_idx++] = crc_c;
          }
        }

        // Verify CRC
        unsigned short calc_crc = crc16(data_buffer, data_pos);
        calc_crc = crc16_update(calc_crc, frame_end);
        unsigned short recv_crc = (crc_bytes[0] << 8) | crc_bytes[1];

        if (calc_crc != recv_crc) {
          fprintf(stderr, "Data CRC mismatch: calculated %04X, received %04X\n",
                  calc_crc, recv_crc);
          return STATUS_CRC_ERROR;
        }

        // Write data to file
        if (file_fd >= 0) {
          ssize_t written = write(file_fd, data_buffer, data_pos);
          if (written < 0 || (size_t)written != data_pos) {
            fprintf(stderr, "Error writing to file\n");
            return STATUS_ERROR;
          }
          bytes_received += data_pos;
        } else {
          fprintf(stderr, "No file open for writing\n");
          return STATUS_ERROR;
        }

        // Handle frame end type
        if (frame_end == ZCRCW || frame_end == ZCRCQ) {
          // Send ZACK
          send_zack(file_pos + data_pos);
        }

        if (frame_end == ZCRCE || frame_end == ZCRCW) {
          // Frame ends, expect new header
          return STATUS_OK;
        }

        // ZCRCG or ZCRCQ - more data follows
        data_pos = 0;
        escape_next = false;
        continue;
      }

      // Normal escaped character
      if ((c & 0x60) == 0x40) {
        data_buffer[data_pos++] = c ^ 0x40;
      } else {
        data_buffer[data_pos++] = c;
      }
      escape_next = false;

      // Check buffer overflow
      if (data_pos >= sizeof(data_buffer)) {
        fprintf(stderr, "Data buffer overflow\n");
        return STATUS_ERROR;
      }
    } else if (c == ZDLE) {
      escape_next = true;
    } else {
      data_buffer[data_pos++] = c;

      // Check buffer overflow
      if (data_pos >= sizeof(data_buffer)) {
        fprintf(stderr, "Data buffer overflow\n");
        return STATUS_ERROR;
      }
    }
  }
}

int main() {
  struct termios old_tio, new_tio;

  // Get current terminal settings
  tcgetattr(STDIN_FILENO, &old_tio);

  // Configure new terminal settings
  new_tio = old_tio;

  // Disable canonical mode (line buffering)
  new_tio.c_lflag &= ~ICANON;

  // Disable echo
  new_tio.c_lflag &= ~ECHO;

  // Disable signal generation (Ctrl-C, Ctrl-Z, etc.)
  new_tio.c_lflag &= ~ISIG;

  // Disable special processing of input characters
  new_tio.c_iflag &= ~(IXON | IXOFF | IXANY); // Disable XON/XOFF flow control
  new_tio.c_iflag &= ~(INLCR | ICRNL);        // Disable newline conversion

  // Set raw mode for output
  new_tio.c_oflag &= ~OPOST; // Disable output processing

  // Set minimum number of bytes and timeout for read
  new_tio.c_cc[VMIN] = 0;  // Non-blocking read
  new_tio.c_cc[VTIME] = 1; // 0.1 second timeout

  // Apply new settings
  tcsetattr(STDIN_FILENO, TCSANOW, &new_tio);

  // Make stdout unbuffered for immediate communication with sz
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stdin, NULL, _IONBF, 0);

  fprintf(stderr, "ZMODEM Receiver - waiting for file...\n");

  // Send initial ZRINIT
  send_zrinit();

  ZFrame frame;
  bytes_received = 0;

  while (true) {
    ZReceiveStatus status = receive_frame(&frame);

    if (status == STATUS_TIMEOUT) {
      fprintf(stderr, "Timeout waiting for data\n");
      break;
    }

    if (status == STATUS_CRC_ERROR) {
      fprintf(stderr, "CRC error\n");
      continue;
    }

    if (status != STATUS_OK) {
      fprintf(stderr, "Error receiving frame\n");
      break;
    }

    printf("Received frame type: %d\n", frame.type);

    switch (frame.type) {
    case ZRQINIT:
      send_zrinit();
      break;

    case ZFILE:
      handle_zfile(&frame);
      break;

    case ZDATA:
      status = handle_zdata(&frame);
      if (status != STATUS_OK) {
        fprintf(stderr, "Error receiving data\n");
        if (status == STATUS_CRC_ERROR) {
          // Request retransmission at current position
          send_zrpos(bytes_received);
          // send_zack(bytes_received);
        }
      }
      break;

    case ZEOF:
      fprintf(stderr, "End of file, received %zu bytes\n", bytes_received);
      if (file_fd >= 0) {
        close(file_fd);
        file_fd = -1;
      }
      send_zrinit();
      bytes_received = 0;
      break;

    case ZFIN:
      fprintf(stderr, "Transfer complete\n");
      send_zfin();

      // Wait for "OO" (over and out) from sender
      unsigned char oo[2];
      read_byte_timeout(&oo[0], 1000);
      read_byte_timeout(&oo[1], 1000);

      // Restore terminal settings
      tcsetattr(STDIN_FILENO, TCSANOW, &old_tio);

      return 0;

    default:
      fprintf(stderr, "Unknown frame type: %d\n", frame.type);
      break;
    }

    receive_state = ZRECV_WAIT_ZPAD;
  }

  if (file_fd >= 0) {
    close(file_fd);
  }

  // Restore terminal settings before exit
  tcsetattr(STDIN_FILENO, TCSANOW, &old_tio);

  return 0;
}