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

// CRC-32 calculation
static unsigned int crc32_update(unsigned int crc, unsigned char data) {
  static const unsigned int crc_table[256] = {
      0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA, 0x076DC419, 0x706AF48F,
      0xE963A535, 0x9E6495A3, 0x0EDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988,
      0x09B64C2B, 0x7EB17CBD, 0xE7B82D07, 0x90BF1D91, 0x1DB71064, 0x6AB020F2,
      0xF3B97148, 0x84BE41DE, 0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7,
      0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC, 0x14015C4F, 0x63066CD9,
      0xFA0F3D63, 0x8D080DF5, 0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172,
      0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B, 0x35B5A8FA, 0x42B2986C,
      0xDBBBC9D6, 0xACBCF940, 0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59,
      0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116, 0x21B4F4B5, 0x56B3C423,
      0xCFBA9599, 0xB8BDA50F, 0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924,
      0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D, 0x76DC4190, 0x01DB7106,
      0x98D220BC, 0xEFD5102A, 0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433,
      0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818, 0x7F6A0DBB, 0x086D3D2D,
      0x91646C97, 0xE6635C01, 0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E,
      0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457, 0x65B0D9C6, 0x12B7E950,
      0x8BBEB8EA, 0xFCB9887C, 0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65,
      0x4DB26158, 0x3AB551CE, 0xA3BC0074, 0xD4BB30E2, 0x4ADFA541, 0x3DD895D7,
      0xA4D1C46D, 0xD3D6F4FB, 0x4369E96A, 0x346ED9FC, 0xAD678846, 0xDA60B8D0,
      0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9, 0x5005713C, 0x270241AA,
      0xBE0B1010, 0xC90C2086, 0x5768B525, 0x206F85B3, 0xB966D409, 0xCE61E49F,
      0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4, 0x59B33D17, 0x2EB40D81,
      0xB7BD5C3B, 0xC0BA6CAD, 0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A,
      0xEAD54739, 0x9DD277AF, 0x04DB2615, 0x73DC1683, 0xE3630B12, 0x94643B84,
      0x0D6D6A3E, 0x7A6A5AA8, 0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1,
      0xF00F9344, 0x8708A3D2, 0x1E01F268, 0x6906C2FE, 0xF762575D, 0x806567CB,
      0x196C3671, 0x6E6B06E7, 0xFED41B76, 0x89D32BE0, 0x10DA7A5A, 0x67DD4ACC,
      0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5, 0xD6D6A3E8, 0xA1D1937E,
      0x38D8C2C4, 0x4FDFF252, 0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B,
      0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60, 0xDF60EFC3, 0xA867DF55,
      0x316E8EEF, 0x4669BE79, 0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236,
      0xCC0C7795, 0xBB0B4703, 0x220216B9, 0x5505262F, 0xC5BA3BBE, 0xB2BD0B28,
      0x2BB45A92, 0x5CB36A04, 0xC2D7FFA7, 0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D,
      0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A, 0x9C0906A9, 0xEB0E363F,
      0x72076785, 0x05005713, 0x95BF4A82, 0xE2B87A14, 0x7BB12BAE, 0x0CB61B38,
      0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21, 0x86D3D2D4, 0xF1D4E242,
      0x68DDB3F8, 0x1FDA836E, 0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777,
      0x88085AE6, 0xFF0F6A70, 0x66063BCA, 0x11010B5C, 0x8F659EFF, 0xF862AE69,
      0x616BFFD3, 0x166CCF45, 0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2,
      0xA7672661, 0xD06016F7, 0x4969474D, 0x3E6E77DB, 0xAED16A4A, 0xD9D65ADC,
      0x40DF0B66, 0x37D83BF0, 0xA9BCAE53, 0xDEBB9EC5, 0x47B2CF7F, 0x30B5FFE9,
      0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6, 0xBAD03605, 0xCDD70693,
      0x54DE5729, 0x23D967BF, 0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94,
      0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D};
  return (crc >> 8) ^ crc_table[(crc ^ data) & 0xFF];
}

static unsigned int crc32(const unsigned char *data, size_t len) {
  unsigned int crc = 0xFFFFFFFF;
  for (size_t i = 0; i < len; i++) {
    crc = crc32_update(crc, data[i]);
  }
  return crc ^ 0xFFFFFFFF;
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
          send_zack(bytes_received);
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

  return 0;
}