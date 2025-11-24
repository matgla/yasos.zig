/*
 Copyright (c) 2025 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#include "terminal.h"

#include <stdio.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static struct termios old_tio;

int prepare_terminal() {
  struct termios new_tio;

  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stdin, NULL, _IONBF, 0);

  if (tcgetattr(STDIN_FILENO, &old_tio) < 0) {
    perror("Failed to get terminal attributes");
    return -1; // Error
  }
  new_tio = old_tio;

  new_tio.c_cflag |= CS8;    // 8-bit characters
  new_tio.c_iflag |= IGNBRK; // Ignore break
  new_tio.c_lflag = 0;       // Disable echo/signals/canonical mode
  new_tio.c_oflag = 0;       // Disable output processing
  new_tio.c_cc[VMIN] = 1;    // Minimum number of characters to read
  new_tio.c_cc[VTIME] = 30;  // 1s timeout for read
  new_tio.c_iflag &= ~(IXON | IXOFF | IXANY); // Disable XON/XOFF flow control
  new_tio.c_cflag |=
      (CLOCAL | CREAD); // Enable receiver, ignore modem control lines
  new_tio.c_cflag &= ~(PARENB | PARODD); // No parity
  new_tio.c_cflag &= ~CSTOPB;            // 1 stop bit
  // Apply new settings
  if (tcsetattr(STDIN_FILENO, TCSANOW, &new_tio) < 0) {
    perror("Failed to set terminal attributes");
    return -1; // Error
  }
  return 0;
}

void restore_terminal() {
  // Restore old terminal settings
  tcsetattr(STDIN_FILENO, TCSANOW, &old_tio);
}

void flush_stdin() {
  int bytes_available;
  ioctl(STDIN_FILENO, FIONREAD, &bytes_available);
  while (bytes_available > 0) {
    char discard_buffer[256];
    int to_read = (bytes_available > sizeof(discard_buffer))
                      ? sizeof(discard_buffer)
                      : bytes_available;
    read(STDIN_FILENO, discard_buffer, to_read);
    bytes_available -= to_read;
  }
}

int read_bytes(void *buf, size_t count) {
  return read(STDIN_FILENO, buf, count);
}

uint8_t read_byte() {
  uint8_t byte = 0;
  int rc = read(STDIN_FILENO, &byte, 1);
  return byte;
}
