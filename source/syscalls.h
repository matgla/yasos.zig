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

#include <stddef.h>
#include <sys/types.h>
#include <errno.h>
#include <stdbool.h>

typedef struct optional_errno {
    int err;
    bool isset;
} optional_errno;

typedef struct read_context { 
    int fd;
    void* buf;
    size_t count;
} read_context;

typedef struct kill_context {
    pid_t pid;
    int sig;
} kill_context;

typedef struct write_context {
    int fd;
    const void* buf;
    size_t count;
} write_context;

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

} syscall_id;

