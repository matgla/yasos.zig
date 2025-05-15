/*
 *   Copyright (c) 2025 Mateusz Stadnik

 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.

 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.

 *   You should have received a copy of the GNU General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

typedef struct syscall_result {
  int err; // errno returned by OS
  int result;
} syscall_result;

typedef struct read_context {
  int fd;
  void *buf;
  size_t count;
  ssize_t *result;
} read_context;

typedef struct kill_context {
  pid_t pid;
  int sig;
} kill_context;

typedef struct write_context {
  int fd;
  const void *buf;
  size_t count;
  ssize_t *result;
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
  off_t *result;
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

typedef struct getdents_context {
  int fd;
  struct dirent *dirp;
  size_t count;
  ssize_t *result;
} getdents_context;

typedef struct ioctl_context {
  int fd;
  int op;
  void *arg;
} ioctl_context;

typedef struct gettimeofday_context {
  struct timeval *tv;
  struct timezone *tz;
} gettimeofday_context;

typedef struct waitpid_context {
  pid_t pid;
  int *status;
  int options;
} waitpid_context;

typedef struct nanosleep_context {
  const struct timespec *req;
  struct timespec *rem;
} nanosleep_context;

typedef struct execve_context {
  const char *filename;
  char **const argv;
  char **const envp;
} execve_context;

typedef struct mmap_context {
  void *addr;
  int length;
  int prot;
  int flags;
  int fd;
  int offset;
  void **result;
} mmap_context;

typedef struct munmap_context {
  void *addr;
  int length;
} munmap_context;

typedef struct getcwd_context {
  char *buf;
  size_t size;
  char **result;
} getcwd_context;

typedef struct chdir_context {
  const char *path;
} chdir_context;

typedef struct time_context {
  time_t *timep;
  time_t *result;
} time_context;

typedef struct fcntl_context {
  int fd;
  int op;
  void *arg;
} fcntl_context;

typedef struct remove_context {
  const char *pathname;
} remove_context;

typedef struct realpath_context {
  const char *path;
  char *resolved_path;
} realpath_context;

typedef struct mprotect_context {
  void *addr;
  size_t length;
  int prot;
} mprotect_context;

typedef struct dlopen_context {
  const char *path;
  int flags;
  void **result;
} dlopen_context;

typedef struct dlclose_context {
  void *handle;
} dlclose_context;

typedef struct dlsym_context {
  void *handle;
  const char *symbol;
  void **result;
} dlsym_context;

typedef enum SystemCall {
  sys_start_root_process = 1,
  sys_create_process,
  sys_semaphore_acquire,
  sys_semaphore_release,
  sys_getpid,
  sys_mkdir,
  sys_fstat,
  sys_isatty,
  sys_open,
  sys_close,
  sys_exit,
  sys_read,
  sys_kill,
  sys_write,
  sys_vfork,
  sys_unlink,
  sys_link,
  sys_stat,
  sys_getentropy,
  sys_lseek,
  sys_wait,
  sys_times,
  sys_getdents,
  sys_ioctl,
  sys_gettimeofday,
  sys_waitpid,
  sys_execve,
  sys_nanosleep,
  sys_mmap,
  sys_munmap,
  sys_getcwd,
  sys_chdir,
  sys_time,
  sys_fcntl,
  sys_remove,
  sys_realpath,
  sys_mprotect,
  sys_dlopen,
  sys_dlclose,
  sys_dlsym,
  SYSCALL_COUNT,
} SystemCall;

int trigger_syscall(int number, const void *args);
