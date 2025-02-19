//
// stdio.zig
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

#include <sys/types.h>

#include <errno.h>
#include <regex.h>
#include <stdarg.h>
#include <unistd.h>

#include <sys/time.h>
#include <sys/times.h>

#include "syscalls.h"

#include "unwind.h"

void __attribute__((noinline)) __attribute__((naked))
trigger_supervisor_call(int number, const void *args, void *result,
                        optional_errno *err) {
  asm inline("svc 0");
}

void inline trigger_syscall(int number, const void *args, void *result) {
  optional_errno err;
  trigger_supervisor_call(number, NULL, &result, &err);
  if (err.isset) {
    errno = err.err;
  }
}

pid_t _getpid() {
  pid_t result;
  trigger_syscall(sys_getpid, NULL, &result);
  return result;
}

int sigprocmask(int how, const sigset_t *_Nullable restrict set,
                sigset_t *_Nullable restrict oldset) {
  // TODO: implement
  return 0;
}

int _close(int fd) {
  int result;
  trigger_syscall(sys_close, &fd, &result);
  return result;
}

int _fcntl(int filedes, int cmd, ...) {
  // TODO: implement
  return 0;
}

void _exit(int status) {
  trigger_syscall(sys_exit, &status, NULL);
  while (1) {
  }
}

ssize_t _read(int fd, void *buf, size_t count) {
  ssize_t result;
  const read_context context = {.fd = fd, .buf = buf, .count = count};
  trigger_syscall(sys_read, &context, &result);
  return result;
}

int _gettimeofday(struct timeval *restrict tv,
                  struct timezone *_Nullable restrict tz) {
  // TODO implement
  return 0;
}

wint_t _jp2uc_l(wint_t c) {
  // TODO: implement if needed
  return 0;
}

wint_t _uc2jp_l(wint_t c, struct __locale_t *l) { return 0; }

int _kill(pid_t pid, int sig) {
  const kill_context context = {
      pid = pid,
      sig = sig,
  };
  int result;
  trigger_syscall(sys_kill, &context, &result);
  return result;
}

ssize_t _write(int fd, const void *buf, size_t count) {
  ssize_t result;
  const write_context context = {
      .fd = fd,
      .buf = buf,
      .count = count,
  };
  trigger_syscall(sys_write, &context, &result);
  return result;
}

pid_t _fork() {
  pid_t result;
  trigger_syscall(sys_fork, NULL, &result);
  return result;
}

int _unlink(const char *pathname) {
  int result;
  trigger_syscall(sys_unlink, pathname, &result);
  return result;
}

int _execve(const char *pathname, char *const _Nullable argv[],
            char *const _Nullable envp[]) {
  // TODO: implement
  return 0;
}

void __libc_fini(void *array) {
  typedef void (*Destructor)();
  Destructor *fini_array = (Destructor *)(array);
  // first must be -1 last must be 0
  const Destructor minus1 = (Destructor)(-1);
  if (array == NULL || fini_array[0] != minus1) {
    return;
  }

  int count = 0;
  while (fini_array[count] != NULL) {
    ++count;
  }

  while (count > 0) {
    if (fini_array[count] != minus1) {
      fini_array[count--]();
    }
  }
}

void _fini() {}

int _link(const char *oldpath, const char *newpath) {
  int result;
  const link_context context = {
      .oldpath = oldpath,
      .newpath = newpath,
  };
  trigger_syscall(sys_link, &context, &result);
  return result;
}

int regexec(const regex_t *preg, const char *string, size_t nmatch,
            regmatch_t pmatch[], int eflags) {
  return 0;
}

int regcomp(regex_t *preg, const char *regex, int cflags) { return 0; }

void regfree(regex_t *preg) {
  // TODO: implement
}

// https://android.googlesource.com/platform/bionic/+/ics-mr1-release/libc/arch-arm/bionic/exidx_dynamic.c
_Unwind_Ptr __gnu_Unwind_Find_exidx(_Unwind_Ptr pc, int *pcount) {
  // todo implement
  return 0;
}

void *__dso_handle = 0;

void _ZSt24__throw_out_of_range_fmtPKcz(const char *__fmt, ...) {
  // print panic
  return;
}

int _mkdir(const char *path, mode_t mode) {
  int result;
  const mkdir_context context = {
      .path = path,
      .mode = mode,
  };
  trigger_syscall(sys_mkdir, &context, &result);
  return result;
}

off_t _lseek(int fd, off_t offset, int whence) {
  off_t result;
  const lseek_context context = {
      fd = fd,
      offset = offset,
      whence = whence,
  };
  trigger_syscall(sys_lseek, &context, &result);
  return result;
}

int _isatty(int fd) {
  int result;
  trigger_syscall(sys_isatty, &fd, &result);
  return result;
}

pid_t _wait(int *_Nullable wstatus) {
  pid_t result;
  trigger_syscall(sys_wait, wstatus, &result);
  return result;
}

int _getentropy(void *buffer, size_t length) {
  int result;
  const getentropy_context context = {
      .buffer = buffer,
      .length = length,
  };
  trigger_syscall(sys_getentropy, &context, &result);
  return result;
}

int _stat(const char *restrict pathname, struct stat *restrict statbuf) {
  int result;
  const stat_context context = {
      .pathname = pathname,
      .statbuf = statbuf,
  };
  trigger_syscall(sys_stat, &context, &result);
  return result;
}

clock_t _times(struct tms *buf) {
  clock_t result;
  trigger_syscall(sys_stat, buf, &result);
  return result;
}

void _init() {}

void *_sbrk(intptr_t increment) {
  void *result;
  trigger_syscall(sys_sbrk, &increment, &result);
  return result;
}

int _open(const char *filename, int flags, ...) {
  va_list args;
  va_start(args, flags);
  int mode = va_arg(args, int);
  va_end(args);
  const open_context context = {
      .path = filename,
      .flags = flags,
      .mode = mode,
  };
  int result;
  trigger_syscall(sys_open, &context, &result);
  return result;
}

int _fstat(int fd, struct stat *buf) {
  int result;
  const fstat_context context = {
      .fd = fd,
      .buf = buf,
  };
  trigger_syscall(sys_fstat, &context, &result);
  return result;
}
