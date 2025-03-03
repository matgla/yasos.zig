/**
 * semaphore.c
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

#include "semaphore.h"

#include <stddef.h>

int    sem_close(sem_t * semaphore)
{
  return 0;
}

int    sem_destroy(sem_t * semaphore)
{
  return 0;
}
int    sem_getvalue(sem_t *semaphore, int * value)
{
  return 0;
}
int    sem_init(sem_t * semaphore, int v, unsigned int x)
{
  return 0;
}
sem_t *sem_open(const char * path, int t, ...)
{
  return NULL;
}
int    sem_post(sem_t * semaphore)
{
  return 0;
}
int    sem_trywait(sem_t * semaphore)
{
  return 0;
}
int    sem_unlink(const char * path)
{
  return 0;
}
int    sem_wait(sem_t * semaphore)
{
  return 0;
}
