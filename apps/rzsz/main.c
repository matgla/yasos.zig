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

// X-modem is easier
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "crc16.h"
#include "packet.h"
#include "terminal.h"

#define MAX_RETRIES 20

typedef enum {
  SOH = 0x01,
  STX = 0x02,
  EOT = 0x04,
  ACK = 0x06,
  NAK = 0x15,
  ETB = 0x17,
  CAN = 0x18,
  C = 0x43,
} ymodem_commands_t;

typedef enum {
  STATE_IDLE,
  STATE_METADATA,
  STATE_DATA,
  STATE_EOT,
  STATE_END,
} ymodem_state_t;

typedef enum {
  STATUS_OK = 0,
  STATUS_ERROR = -1,
  STATUS_INVALID_START = -2,
  STATUS_CRC_ERROR = -3,
  STATUS_TIMEOUT = -4,
  STATUS_INVALID_COMPLEMENTARY = -5,
} ymodem_status_t;

typedef struct {
  ymodem_state_t state;
  int retries;
  int fd;
  int filesize;
  int received_bytes;
} ymodem_statemachine_t;

void send_command(char c) {
  putchar(c);
  fflush(stdout);
}

void send_nack(ymodem_statemachine_t *sm) {
  // drop remaining input
  flush_stdin();
  putchar(NAK);
  fflush(stdout);
  sm->retries++;
}

ymodem_status_t read_packet(ymodem_packet_t *packet) {
  do {
    if (read(STDIN_FILENO, &packet->start, 1) <= 0) {
      // fprintf(stderr, "Timeout waiting for start byte\n");
      return STATUS_ERROR;
    }
    // fprintf(stderr, "Got start byte: 0x%02X\n", packet->start);
  } while (packet->start != SOH && packet->start != STX &&
           packet->start != EOT && packet->start != EOF);

  if (packet->start == EOT) {
    return STATUS_OK;
  }
  packet->id = read_byte();
  uint8_t complementary_packet_id = read_byte();
  // fprintf(stderr, "Got packet ID: 0x%02X, complement: 0x%02X\n", packet->id,
          // complementary_packet_id);

  if (packet->id + complementary_packet_id != 0xFF) {
    // fprintf(stderr, "Packet ID and its complement do not match\n");
    flush_stdin();
    return STATUS_ERROR;
  }

  int packet_size = 0;

  if (packet->start == SOH) {
    packet_size = 128;
  } else if (packet->start == STX) {
    packet_size = 1024;
  } else if (packet->start == EOF) {
    packet_size = 0;
    return STATUS_OK;
  } else {
    // fprintf(stderr, "Invalid start byte: 0x%02X\n", packet->start);
    flush_stdin();
    return STATUS_ERROR;
  }

  int readed = 0;
  while (readed < packet_size) {
    int rc = read(STDIN_FILENO, packet->data + readed, packet_size - readed);
    // fprintf(stderr, "Read %d bytes, total readed: %d/%d\n", rc, readed + rc,
    //         packet_size);
    // for (int i = 0; i < rc; i++) {
    //   fprintf(stderr, "[%c]%d", packet->data[readed + i], packet->data[readed + i]);
    // }
    // fprintf(stderr, "\n");
    if (rc <= 0) {
      // fprintf(stderr, "Timeout reading packet data\n");
      return STATUS_ERROR;
    }
    readed += rc;
  }
  packet->crc[0] = read_byte();
  packet->crc[1] = read_byte();
  uint16_t computed_crc = crc16_ccitt(packet->data, packet_size);

  if (packet->crc[0] != computed_crc >> 8 ||
      packet->crc[1] != (computed_crc & 0xFF)) {
    // fprintf(stderr, "CRC mismatch: received 0x%02X%02X, computed 0x%04X\n",
            // packet->crc[0], packet->crc[1], computed_crc);
    return STATUS_ERROR;
  }
  return STATUS_OK;
}

bool ymodem_should_continue(ymodem_statemachine_t *sm) {
  return sm->retries < MAX_RETRIES;
}

void ymodem_process_idle(ymodem_statemachine_t *sm) {
  // fprintf(stderr, "Sending initial C to start transfer...\n");
  flush_stdin();
  send_command(C);
  sm->state = STATE_METADATA;
}

void ymodem_process_metadata(ymodem_statemachine_t *sm) {
  ymodem_packet_t packet;
  // fprintf(stderr, "Waiting for metadata packet...\n");
  ymodem_status_t status = read_packet(&packet);
  // fprintf(stderr, "Metadata packet received, status: %d\n", status);
  if (status == STATUS_OK) {
    if (packet.id == 0) {
      // Process metadata packet
      sm->state = STATE_DATA;
      sm->retries = 0;
      sm->filesize =
          atoi((char *)packet.data + strlen((char *)packet.data) + 1);
      sm->fd = open((char *)packet.data, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      send_command(ACK);
      // fprintf(stderr, "Receiving file: %s, with size: %d\n", packet.data,
      // sm->filesize);
      send_command(C);
      sm->state = STATE_DATA;
      return;
    }
  }
  sm->state = STATE_IDLE;
  sm->retries++;
  flush_stdin();
}

void ymodem_process_data(ymodem_statemachine_t *sm) {
  ymodem_packet_t packet;
  memset(&packet, 0, sizeof(ymodem_packet_t));
  ymodem_status_t status = read_packet(&packet);
  if (status == STATUS_OK) {
    if (packet.start == EOT) {
      send_command(NAK);
      sm->state = STATE_EOT;
      return;
    } else if (packet.start == SOH || packet.start == STX) {
      // Here you would write packet.data to the file
      int to_write = (packet.start == SOH) ? 128 : 1024;
      if (sm->received_bytes + to_write > sm->filesize) {
        to_write = sm->filesize - sm->received_bytes;
      }
      write(sm->fd, packet.data, to_write);
      sm->received_bytes += to_write;
      sm->retries = 0;
      send_command(ACK);
      return;
    }
  }
  send_nack(sm);
}

void ymodem_process_eot(ymodem_statemachine_t *sm) {
  if (read_byte() == EOT) {
    send_command(ACK);
    send_command(C);
    ymodem_packet_t empty_packet;
    ymodem_status_t empty_status = read_packet(&empty_packet);
    if (empty_status == STATUS_OK && empty_packet.id == 0) {
      send_command(ACK);
      sm->state = STATE_END;
      return;
    }
  }
  send_nack(sm);
}

void ymodem_receiver_loop() {
  ymodem_statemachine_t sm;
  sm.state = STATE_IDLE;
  sm.filesize = 0;
  sm.retries = 0;
  sm.received_bytes = 0;

  while (ymodem_should_continue(&sm)) {
    switch (sm.state) {
    case STATE_IDLE:
      ymodem_process_idle(&sm);
      break;
    case STATE_METADATA:
      ymodem_process_metadata(&sm);
      break;
    case STATE_DATA:
      ymodem_process_data(&sm);
      break;
    case STATE_EOT:
      ymodem_process_eot(&sm);
      // Handle end of transmission
      break;
    case STATE_END:
      // Finalize and exit
      close(sm.fd);
      return;
    }
  }
}

int main(int argc, char *argv[]) {
  prepare_terminal();
  flush_stdin();
  fprintf(stderr, "Starting YMODEM receiver...\n");
  ymodem_receiver_loop();
  flush_stdin();
  fprintf(stderr, "YMODEM transfer completed...\n");
  restore_terminal();
  return 0;
}