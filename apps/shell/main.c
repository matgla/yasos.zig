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

#include <unistd.h>

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <dirent.h>
#include <termios.h>

#include <sys/types.h>
#include <sys/wait.h>

#define MAX_LINE_SIZE 255
#define MAX_HISTORY_LINES 4
#define MAX_NUMBER_OF_ARGUMENTS 16

static struct termios termios_original;
static struct termios termios_stdout_original;
static struct termios termios_raw;

typedef struct Screen {
  char lines[MAX_HISTORY_LINES][MAX_LINE_SIZE];
  int current_line;
} Screen;

static Screen screen;

static void enable_raw_mode() {
  tcgetattr(STDIN_FILENO, &termios_original);
  tcgetattr(STDOUT_FILENO, &termios_stdout_original);
  termios_raw = termios_original;
  termios_raw.c_lflag &= ~(ICANON | ECHO);
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &termios_raw);
  termios_raw = termios_stdout_original;
  termios_raw.c_lflag &= ~(ICANON | ECHO);
  tcsetattr(STDOUT_FILENO, TCSANOW, &termios_raw);
}

static void disable_raw_mode() {
  termios_raw.c_lflag |= (ICANON | ECHO);
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &termios_raw);
  tcsetattr(STDOUT_FILENO, TCSANOW, &termios_raw);
}

char *strip(char *str, size_t length) {
  while (isspace(*str) && (length-- != 0))
    str++;
  return str;
}

void scanline(char *buffer, size_t size) {
  char ch;
  size_t i = 0;
  size_t cursor_pos = 0;
  int got_not_space = false;

  if (size != 0) {
    buffer[0] = 0;
  }

  while (((ch = fgetc(stdin)) != EOF) && (ch != '\n')) {
    if (ch == ' ' && !got_not_space) {
      continue;
    }

    if (ch == 27) {
      // handle escape sequence
      ch = fgetc(stdin);
      if (ch == '[') {
        ch = fgetc(stdin);
        if (ch == 'A') {
          // up arrow
          if (screen.current_line < MAX_HISTORY_LINES - 1) {
            screen.current_line++;
            printf("\033[1A");
            printf("\033[K");
            printf("%s", screen.lines[screen.current_line]);
            fflush(stdout);
          }
          continue;
        } else if (ch == 'B') {
          // down arrow
          continue;
        } else if (ch == 'C') {
          if (cursor_pos < i) {
            ++cursor_pos;
            printf("\033[C");
            fflush(stdout);
          }
          continue;
        } else if (ch == 'D') {
          if (cursor_pos > 0) {
            --cursor_pos;
            printf("\033[D");
            fflush(stdout);
          }
          // left arrow
          continue;
        }
      }
      continue;
    }

    got_not_space = true;
    if (ch == '\t') {
      // handle tab, but for now just backspace
      continue;
    } else if (ch == '\b' || ch == 127) {
      if (i > 0 && cursor_pos > 0) {
        if (cursor_pos == i) {
          buffer[i - 1] = '\0';
          printf("\033[D ");
        } else {
          memmove(&buffer[cursor_pos - 1], &buffer[cursor_pos], i - cursor_pos);
          buffer[i - 1] = '\0';
          printf("\033[D%s ", &buffer[cursor_pos - 1]);
        }
        cursor_pos--;
        printf("\033[%dD", i - cursor_pos);
        fflush(stdout);
        i--;
      }
      continue;
    }

    if (i < size - 1 && got_not_space) {
      if (cursor_pos != i) {
        memmove(&buffer[cursor_pos + 1], &buffer[cursor_pos], i - cursor_pos);
        buffer[cursor_pos] = ch;
        printf("%s", &buffer[cursor_pos]);
        printf("\033[%dD", i - cursor_pos);
      } else {
        printf("%c", ch);
        buffer[cursor_pos] = ch;
      }

      fflush(stdout);
      i++;
      cursor_pos++;
    }
  }
  buffer[i] = '\0';
}

bool is_environment_variable(const char *buffer) {
  return strchr(buffer, '=') != NULL;
}

int process_change_directory(char *args[]) {
  if (args[1] == NULL) {
    printf("cd: missing argument\n");
    return 0;
  }

  if (args[1][0] == '/') {
    // absolute path
    if (chdir(args[1]) != 0) {
      printf("cd: %s: No such file or directory\n", args[1]);
    }
    return 0;
  }

  char buf[255];
  if (getcwd(buf, sizeof(buf)) == NULL) {
    printf("cd: getcwd failed\n");
    return 0;
  }

  if (buf[0])
    strcat(buf, "/");
  strcat(buf, args[1]);

  if (chdir(buf) != 0) {
    printf("cd: %s: No such file or directory\n", args[1]);
  }

  return 0;
}

int process_print_current_directory(char *args[]) {
  char buf[255];
  if (getcwd(buf, sizeof(buf)) != NULL) {
    printf("%s\n", buf);
  } else {
    printf("getcwd() error\n");
  }
  return 0;
}

int execute_command(const char *command, char *args[]) {
  printf("\n");
  if (strcmp(command, "exit") == 0) {
    return -1;
  }
  if (strcmp(command, "cd") == 0) {
    return process_change_directory(args);
  }

  if (strcmp(command, "pwd") == 0) {
    return process_print_current_directory(args);
  }

  pid_t pid = vfork();
  if (pid == -1) {
    printf("spawn process failure\n");
  } else if (pid == 0) {
    char cwd[255];

    disable_raw_mode();
    int rc = 0;
    if (getcwd(cwd, sizeof(cwd)) != NULL) {
      strcat(cwd, "/");
      strcat(cwd, command);
      rc = execv(cwd, args);
      if (rc == 0) {
        exit(0);
      }
    }
    rc = execvp(command, args);
    exit(0);
  } else {
    int rc = 0;
    enable_raw_mode();
    waitpid(pid, &rc, 0);
  }
  // try to call command
  return 0;
}

bool is_completion_request(const char *part) {
  return strchr(part, '\t') != NULL;
}

int parse_command(char *buffer) {
  char *args[MAX_NUMBER_OF_ARGUMENTS];
  const char *delimiter = " ";
  bool command_found = false;
  const char *command = NULL;
  int argc = 0;
  char *part = NULL;

  if (strlen(buffer) == 0) {
    printf("\n");
    return 0;
  }
  part = strtok(buffer, delimiter);

  while (part != NULL) {
    if (is_environment_variable(part) && (command == NULL)) {
      // TODO: implement environment variable propagation
    } else if (is_completion_request(part)) {
      // process completion request
      return 0;
    } else if (command == NULL) {
      command = part;
      args[argc++] = part;
    } else {
      if (argc < MAX_NUMBER_OF_ARGUMENTS - 2) {
        args[argc++] = part;
      } else {
        break;
      }
    }

    part = strtok(NULL, delimiter);
  }
  args[argc] = NULL;

  return execute_command(command, args);
}

int main(int argc, char *argv[]) {
  if (isatty(STDIN_FILENO)) {
    enable_raw_mode();
    char ch;
    while (true) {
      printf("$ ");
      fflush(stdout);
      scanline(&screen.lines[screen.current_line], MAX_LINE_SIZE);
      if (parse_command(&screen.lines[screen.current_line]) == -1)
        break;
    }

    disable_raw_mode();
    // run interactive mode
  } else {
    // run script processor
    printf("Run interactive mode\n");
  }
}
