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

#include <unistd.h>
#include <regex.h>

#include <sys/time.h>

#include "syscalls.h"

void __attribute__((noinline)) __attribute__((naked)) trigger_supervisor_call(int number, const void* args, void* result, optional_errno* err)
{
    asm inline ("svc 0");
}

pid_t _getpid() 
{
    pid_t result;
    optional_errno err;
    trigger_supervisor_call(sys_getpid, NULL, &result, &err);
    if (err.isset) {
        errno = err.err;
    }
    return result;
}

int sigprocmask(int how, const sigset_t *_Nullable restrict set,
                sigset_t *_Nullable restrict oldset)
{
    // TODO: implement
    return 0;
}

int _close(int fd)
{
    int result;
    optional_errno err;
    trigger_supervisor_call(sys_close, &fd, &result, &err);
    if (err.isset)
    {
        errno = err.err;
    }
    return result;
}

int _fcntl(int filedes, int cmd, ...)
{
    // TODO: implement
    return 0;
}

void regfree(regex_t *preg)
{
    // TODO: implement
}


void _exit(int status)
{
    optional_errno err;
    trigger_supervisor_call(sys_exit, &status, NULL, &err);
    if (err.isset) {
        errno = err.err;
    }
    while (1) {}
}

ssize_t _read(int fd, void* buf, size_t count)
{
    ssize_t result;
    optional_errno err;
    const read_context context = {
        .fd = fd,
        .buf = buf,
        .count = count
    };
    trigger_supervisor_call(sys_read, &context, &result, &err);
    if (err.isset) {
        errno = err.err;
    }
    return result;
}

int _gettimeofday(struct timeval *restrict tv,
    struct timezone *_Nullable restrict tz)
{
    // TODO implement
    return 0;
}

wint_t _jp2uc_l(wint_t c)
{
    // TODO: implement if needed
    return 0;
}

int _kill(pid_t pid, int sig)
{
    optional_errno err;
    const kill_context context = {
        pid = pid,
        sig = sig,
    };
    int result;
    trigger_supervisor_call(sys_kill, &context, &result, &err);
    if (err.isset) {
        errno = err.err;
    }
    return result;
}

ssize_t _write(int fd, const void* buf, size_t count)
{
    ssize_t result;
    const write_context context = {
        .fd = fd, 
        .buf = buf,
        .count = count,
    };
    optional_errno err;
    trigger_supervisor_call(sys_write, &context, &result, &err);
    if (err.isset) {
        errno = err.err;
    }
    return result;
}

pid_t _fork()
{
    pid_t result;
    optional_errno err;
    trigger_supervisor_call(sys_fork, NULL, &result, &err);
    if (err.isset) {
        errno = err.err;
    }
    return result;
}

int _unlink(const char *pathname) {
    int result; 
    optional_errno err;
    trigger_supervisor_call(sys_unlink, pathname, &result, &err);
    if (err.isset) {
        errno = err.err;
    }
    return result;
}

int _execve(const char *pathname, char *const _Nullable argv[],
        char *const _Nullable envp[])
{
    // TODO: implement
    return 0;
}

void _fini()
{

}