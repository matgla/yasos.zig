// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

#include <stdarg.h>
#include <libs/libc/sys/syscall.h>
#include <libs/libc/unistd.h>
#include <libs/libc/stdlib.h>
#include <libs/libc/sys/ioctl.h>
#include <libs/libc/termios.h>
#include <libs/libc/dirent.h>
#include <libs/libc/fcntl.h>
#include <libs/libc/errno.h>
#include <libs/libc/sys/stat.h>
#include <libs/libc/sys/sysinfo.h>
#include <libs/libc/sys/mman.h>
#include <libs/libc/sys/resource.h>
