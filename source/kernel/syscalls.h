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

typedef enum SystemCall {
  sys_dynamic_loader_prepare_entry = 1,
  sys_dynamic_loader_process_exit,
  sys_start_root_process,
  sys_create_process,
  sys_semaphore_acquire,
  sys_semaphore_release,
  sys_getpid,
  sys_mkdir,
  sys_fstat,
  sys_isatty,
  sys_open,
  sys_sbrk,
  sys_init,
  sys_close,
  sys_exit,
  sys_read,
  sys_kill,
  sys_write,
  sys_fork,
  sys_unlink,
  sys_link,
  sys_stat,
  sys_getentropy,
  sys_lseek,
  sys_wait,
  sys_times,
} SystemCall;

void trigger_syscall(int number, const void *args, void *result);
