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

#include <stdio.h>
// #include <string.h>
// #include <stdbool.h>
// #include <ctype.h>
// #include <stdlib.h>

// #include <dirent.h>
// #include <termios.h>

// #include <sys/types.h>
// #include <sys/wait.h>

// #define MAX_LINE_SIZE 255
// #define MAX_NUMBER_OF_ARGUMENTS 16

// char *strip(char *str, size_t length)
// {
//   while (isspace(*str) && (length-- != 0)) str++;
//   return str;
// }

// void scanline(char *buffer, size_t size)
// {
//   char ch;
//   size_t i = 0;
//   bool got_not_space = false;

//   if (size != 0)
//   {
//     buffer[0] = 0;
//   }

//   while(((ch = fgetc(stdin)) != EOF) && (ch != '\n'))
//   {
//     if (ch == ' ' && !got_not_space)
//     {
//       continue;
//     }
//
//     got_not_space = true;
//     if (ch == '\t')
//     {
//       // handle tab, but for now just backspace
//       continue;
//     }
//     else if (ch == '\b' || ch == 127)
//     {
//       if (i > 0) {
//         --i;
//         printf("\b \b");
//       }
//       continue;
//     }
//
//     if (i < size - 1 && got_not_space)
//     {
//       printf("%c", ch);
//       buffer[i++] = ch;
//     }
//   }
//   buffer[i] = '\0';
// }

// bool is_environment_variable(const char *buffer)
// {
//   return strchr(buffer, '=') != NULL;
// }

// int execute_command(const char *command, char *args[])
// {
//   printf("\n");
//   if (strcmp(command, "exit") == 0)
//   {
//     return -1;
//   }

//   pid_t pid = fork();
//   if (pid == -1)
//   {
//     printf("spawn process failure\n");
//   }
//   else if (pid == 0)
//   {
//     execvp(command, args);
//   }
//   else
//   {
//     int rc = 0;
//     waitpid(pid, &rc, 0);
//   }
//   // try to call command
//   return 0;
// }

// bool is_completion_request(const char *part)
// {
//   return strchr(part, '\t') != NULL;
// }

// int parse_command(char *buffer)
// {
//   char *args[MAX_NUMBER_OF_ARGUMENTS];
//   const char* delimiter = " ";
//   bool command_found = false;
//   const char *command = NULL;
//   int argc = 0;
//   char *part = NULL;

//   if (strlen(buffer) == 0)
//   {
//     return 0;
//   }
//   part = strtok(buffer, delimiter);

//   while (part != NULL)
//   {
//     if (is_environment_variable(part) && (command == NULL))
//     {
//       // TODO: implement environment variable propagation
//     }
//     else if (is_completion_request(part))
//     {
//       // process completion request
//       return 0;
//     }
//     else if (command == NULL)
//     {
//       command = part;
//       args[argc++] = part;
//     }
//     else
//     {
//       if (argc < MAX_NUMBER_OF_ARGUMENTS - 2)
//       {
//         args[argc++] = part;
//       }
//       else
//       {
//         break;
//       }
//     }

//     part = strtok(NULL, delimiter);
//   }
//   args[argc] = NULL;

//   return execute_command(command, args);
// }

int main(int argc, char *argv[]) {
  if (isatty(STDIN_FILENO)) {
    printf("This is atty\n");
    char buf[50];
    scanf("%s", buf);
    printf("Buffer: '%s'\n", buf);
    //     struct termios termios_original;
    //     struct termios termios_stdout_original;
    //     struct termios termios_raw = {};
    //     tcgetattr(STDIN_FILENO, &termios_original);
    //     tcgetattr(STDOUT_FILENO, &termios_stdout_original);
    //     termios_raw = termios_original;
    //     termios_raw.c_lflag &= ~(ICANON | ECHO);
    //     tcsetattr(STDIN_FILENO, TCSAFLUSH, &termios_raw);
    //     termios_raw = termios_stdout_original;
    //     termios_raw.c_lflag &= ~(ICANON | ECHO);
    //     tcsetattr(STDOUT_FILENO, TCSANOW, &termios_raw);
    //     while (true)
    //     {
    //       printf("$ ");
    //       char buffer[MAX_LINE_SIZE];
    //       scanline(buffer, sizeof(buffer));
    //       if (parse_command(buffer) == -1) break;
    //     }

    //     tcsetattr(STDIN_FILENO, TCSAFLUSH, &termios_original);
    //     tcsetattr(STDOUT_FILENO, TCSAFLUSH, &termios_stdout_original);
    //     // run interactive mode
  } else {
    // run script processor
    printf("Run interactive mode\n");
  }
}
