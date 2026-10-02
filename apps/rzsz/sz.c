/**
 * sz.c
 *
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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
 * File transfer sender: the way back from the board to the PC.
 *
 *   sz [--strip PREFIX] [--list FILE] [file...]
 *
 * Sends every named file (and every line of FILE) in one Zmodem session to the
 * receiver on the other end of the console -- scripts/yasos_device.py's
 * uart_pull, through tests/smoke/framework/file_transfer.receive_files. Each
 * file is announced by its path with PREFIX taken off the front, which is how
 * the PC knows where it goes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include "terminal.h"
#include "zmodem/zmodem.h"

#include <sys/klog.h>

static int add_path(char ***paths, int *count, int *capacity, const char *path) {
  if (*count == *capacity) {
    *capacity = *capacity ? *capacity * 2 : 64;
    char **grown = realloc(*paths, (size_t)*capacity * sizeof(char *));
    if (grown == NULL)
      return -1;
    *paths = grown;
  }
  (*paths)[(*count)++] = strdup(path);
  return 0;
}

static int read_list(const char *list, char ***paths, int *count, int *capacity) {
  FILE *f = fopen(list, "r");
  if (f == NULL) {
    fprintf(stderr, "ERROR: cannot open %s\n", list);
    return -1;
  }
  char line[512];
  while (fgets(line, sizeof(line), f) != NULL) {
    size_t n = strcspn(line, "\r\n");
    line[n] = '\0';
    if (n == 0)
      continue;
    if (add_path(paths, count, capacity, line) < 0) {
      fclose(f);
      return -1;
    }
  }
  fclose(f);
  return 0;
}

int main(int argc, char *argv[]) {
  const char *strip = NULL;
  char **paths = NULL;
  int count = 0, capacity = 0;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--strip") == 0 && i + 1 < argc) {
      strip = argv[++i];
    } else if (strcmp(argv[i], "--list") == 0 && i + 1 < argc) {
      if (read_list(argv[++i], &paths, &count, &capacity) < 0)
        return 1;
    } else if (argv[i][0] == '-') {
      fprintf(stderr, "Usage: sz [--strip PREFIX] [--list FILE] [file...]\n");
      return 1;
    } else if (add_path(&paths, &count, &capacity, argv[i]) < 0) {
      return 1;
    }
  }
  if (count == 0) {
    fprintf(stderr, "Usage: sz [--strip PREFIX] [--list FILE] [file...]\n");
    return 1;
  }

  prepare_terminal();
  /* stdout is a UART file of its own, with termios of its own: take output
     processing off it as well, or file bytes would be translated on the way. */
  struct termios old_out, raw_out;
  int have_out = tcgetattr(STDOUT_FILENO, &old_out) == 0;
  if (have_out) {
    raw_out = old_out;
    raw_out.c_oflag = 0;
    tcsetattr(STDOUT_FILENO, TCSANOW, &raw_out);
  }
  int rc = zmodem_send_batch((const char *const *)paths, count, strip);
  klog_ctl(1);
  if (have_out)
    tcsetattr(STDOUT_FILENO, TCSANOW, &old_out);
  restore_terminal();
  return rc < 0 ? 1 : 0;
}
