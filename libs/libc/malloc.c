/**
 * malloc.c
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

#include "stddef.h"

#ifndef YALIBC_MALLOC_ALIGNMENT 
#define YALIBC_MALLOC_ALIGNMENT 8
#endif

typedef struct memory_block {
  size_t size;
  struct memory_block *next;

} memory_block;

void *heap_start = NULL;
void *heap_end = NULL; 

memory_block root = {0, NULL};

memory_block *find_free_block(size_t size) {
  memory_block *current = &root;
  while (current != NULL) {
    if (current->size >= size) {
      return current;
    }
    current = current->next;
  }
  return NULL;
}

void *malloc(size_t size) {
  if (heap_start == NULL) {
    heap_start = sbrk(size);
    heap_end = heap_start + size;
  }

  memory_block *free_block = find_free_block(size); 

  return NULL;
}