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

#include "stddef.h"

#include "stdalign.h"
#include "unistd.h"

typedef struct memory_block {
  size_t size : 31;
  size_t used : 1;
  struct memory_block *next;
} memory_block;

memory_block root = {0, 0, NULL};
memory_block *last = &root;

static memory_block *find_free_block(size_t size) {
  memory_block *current = &root;
  while (current != NULL) {
    if (!current->used && current->size >= size) {
      return current;
    }
    current = current->next;
  }
  return NULL;
}

static size_t malloc_align(size_t size) {
  return (size + alignof(max_align_t) - 1) & ~(alignof(max_align_t) - 1);
}

void *malloc(size_t size) {
  const size_t memory_block_size = malloc_align(sizeof(memory_block));
  const size_t allocation_size = malloc_align(size) + memory_block_size;

  memory_block *free_block = find_free_block(malloc_align(size));
  if (free_block == NULL) {
    void *new_block = sbrk(allocation_size);
    memset(new_block, 0, memory_block_size);
    if (new_block == (void *)-1) {
      return NULL;
    }
    memory_block *block = (memory_block *)new_block;
    block->size = malloc_align(size);
    block->used = 1;
    block->next = NULL;

    last->next = block;
    last = block;
    return new_block + memory_block_size;
  } else {
    if (free_block->size > size + sizeof(memory_block)) {
      memory_block *new_block =
          (memory_block *)((void *)free_block + allocation_size);
      new_block->size = free_block->size - allocation_size;
      new_block->used = 0;
      new_block->next = free_block->next;
      free_block->next = new_block;
      free_block->size = malloc_align(size);
      free_block->used = 1;
      return (void *)free_block + memory_block_size;
    } else {
      free_block->used = 1;
      return (void *)free_block + memory_block_size;
    }
  }

  return NULL;
}

// TODO: consolidate implementation
void free(void *ptr) {
  if (ptr == NULL) {
    return;
  }
  memory_block *block =
      (memory_block *)((void *)ptr - malloc_align(sizeof(memory_block)));

  if (block->used == 0) {
    return;
  }

  memory_block *parent = &root;
  for (parent = &root; parent != NULL; parent = parent->next) {
    if (parent->next == block) {
      break;
    }
  }
  block->used = 0;
  if (parent != NULL) {
    if (block->next != NULL && block->next->used == 0) {
      block->size += block->next->size + malloc_align(sizeof(memory_block));
      block->next = block->next->next;
    }
    if (parent->used == 0 && parent != &root) {
      parent->size += block->size + malloc_align(sizeof(memory_block));
      parent->next = block->next;
      if (last == block) {
        last = parent;
      }
      block = parent;
    }
  }

  if (last == block) {
    sbrk(-(block->size + malloc_align(sizeof(memory_block))));
    last = parent;
    if (parent != NULL) {
      parent->next = block->next;
    }
    return;
  }
}