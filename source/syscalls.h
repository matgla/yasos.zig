//
// syscalls_id.h
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

typedef struct optional_errno {
  int err;
  bool isset;
} optional_errno;

typedef struct read_context {
  int fd;
  void *buf;
  size_t count;
} read_context;

typedef struct kill_context {
  pid_t pid;
  int sig;
} kill_context;

typedef struct write_context {
  int fd;
  const void *buf;
  size_t count;
} write_context;

typedef struct link_context {
  const char *oldpath;
  const char *newpath;
} link_context;

typedef struct mkdir_context {
  const char *path;
  mode_t mode;
} mkdir_context;

typedef struct lseek_context {
  int fd;
  off_t offset;
  int whence;
} lseek_context;

typedef struct getentropy_context {
  void *buffer;
  size_t length;
} getentropy_context;

typedef struct stat_context {
  const char *pathname;
  struct stat *statbuf;
} stat_context;

typedef struct open_context {
  const char *path;
  int flags;
  int mode;
} open_context;

typedef struct fstat_context {
  int fd;
  struct stat *buf;
} fstat_context;

typedef enum syscall_id {
  sys_start_root_process = 1,
  sys_create_process = 2,
  sys_semaphore_acquire = 3,
  sys_semaphore_release = 4,
  sys_getpid = 5,
  sys_mkdir = 6,
  sys_fstat = 7,
  sys_isatty = 8,
  sys_open = 9,
  sys_sbrk = 10,
  sys_init = 11,
  sys_close = 12,
  sys_exit = 13,
  sys_read = 14,
  sys_kill = 15,
  sys_write = 16,
  sys_fork = 17,
  sys_unlink = 18,
  sys_link = 19,
  sys_stat = 21,
  sys_getentropy = 22,
  sys_lseek = 23,
  sys_wait = 24,
  sys_times = 25,
} syscall_id;
