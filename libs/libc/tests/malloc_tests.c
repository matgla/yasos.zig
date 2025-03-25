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

#include "utest.h"

#include <stdalign.h>

#include "syscalls_stub.h"

void *sut_malloc(intptr_t size);
void sut_free(void *ptr);

typedef struct sbrk_call_context {
  int number;
  intptr_t size;
  void *result;
} sbrk_call_context;

sbrk_call_context context;

typedef struct memory_block {
  size_t size : 31;
  size_t used : 1;
  struct memory_block *next;
} memory_block;

void process_syscall_sbrk(int number, const void *args, void *result,
                          optional_errno *err) {
  context.number = number;
  context.size = *(intptr_t *)args;
  printf("number: %d, sbrk(%d)\n", number, context.size);
  sbrk_result *sbrk_result = result;
  sbrk_result->result = context.result;
}

void reset_context_state() {
  context.number = 0;
  context.size = 0;
  context.result = NULL;
}

int heap_usage = 0;

typedef struct allocation_metadata {
  void *ptr;
  memory_block *block;
  int full_size;
} allocation_metadata;

allocation_metadata test_allocate(int size, void *heap_pointer) {
  void *result;
  reset_context_state();
  context.result = heap_pointer;
  result = sut_malloc(size);
  if (context.number == sys_sbrk) {
    heap_usage += context.size;
  }

  return (allocation_metadata){
      .ptr = result,
      .block = (memory_block *)((void *)result - alignof(max_align_t)),
      .full_size = context.size,
  };
}

int test_free(void *ptr) {
  reset_context_state();
  sut_free(ptr);
  if (context.number == sys_sbrk) {
    heap_usage += context.size;
    return -(context.size);
  }
  return 0;
}

struct malloc_tests {};

UTEST_F_SETUP(malloc_tests) {
  reset_context_state();
}

UTEST_F_TEARDOWN(malloc_tests) {
  ASSERT_EQ(heap_usage, 0);
}

UTEST_F(malloc_tests, allocate) {
  const int memory_block_size = alignof(max_align_t);
  uint8_t heap[128];
  trigger_supervisor_call_fake.custom_fake = process_syscall_sbrk;

  allocation_metadata a0 = test_allocate(sizeof(char), heap);
  char *ptr0 = (char *)a0.ptr;
  *ptr0 = 'a';
  ASSERT_EQ(context.number, sys_sbrk);
  ASSERT_EQ(a0.block->size, alignof(max_align_t));
  ASSERT_EQ(a0.block->used, 1);
  ASSERT_EQ(a0.block->next, NULL);

  void *object_ptr = heap + memory_block_size;
  ASSERT_EQ(*(char *)object_ptr, 'a');

  object_ptr += a0.block->size;
  allocation_metadata a1 = test_allocate(sizeof(int), object_ptr);
  int *ptr1 = (int *)a1.ptr;
  *ptr1 = 0xcafebabe;
  ASSERT_EQ(context.number, sys_sbrk);
  ASSERT_EQ(a0.block->next, a1.block);
  ASSERT_EQ(a1.block->size, alignof(max_align_t));
  ASSERT_EQ(a1.block->used, 1);
  ASSERT_EQ(a1.block->next, NULL);

  object_ptr += memory_block_size;
  ASSERT_EQ(*(int *)(object_ptr), 0xcafebabe);

  object_ptr += a1.block->size;
  allocation_metadata a2 = test_allocate(sizeof(char) * 24, object_ptr);
  char *ptr2 = (char *)a2.ptr;

  const char *msg = "Hello, World!";
  int message_size = strlen(msg) + 1;
  int aligned_size = 24 + (-24 & (alignof(max_align_t) - 1));
  memcpy(ptr2, msg, message_size);
  ASSERT_EQ(a2.block->size, aligned_size);
  ASSERT_EQ(a2.block->used, 1);
  ASSERT_EQ(a0.block->next, a1.block);
  ASSERT_EQ(a1.block->next, a2.block);
  ASSERT_EQ(a2.block->next, NULL);

  object_ptr += memory_block_size;

  ASSERT_EQ(test_free(a2.ptr), a2.full_size);
  ASSERT_EQ(a2.block->next, NULL);
  ASSERT_EQ(a1.block->next, NULL);
  ASSERT_EQ(a0.block->next, a1.block);
  ASSERT_EQ(test_free(a0.ptr), 0);

  // if we allocate the same size as the released block, it should be reused
  allocation_metadata a3 = test_allocate(sizeof(int), NULL);

  ASSERT_EQ(a3.block, a0.block);
  ASSERT_EQ(a3.block->used, 1);
  ASSERT_EQ(a3.block->size, alignof(max_align_t));
  ASSERT_EQ(a0.block->next, a1.block);
  ASSERT_EQ(a1.block->next, NULL);

  ASSERT_EQ(test_free(a3.ptr), 0);
  ASSERT_EQ(a0.block->next, a1.block);
  ASSERT_EQ(a1.block->next, NULL);
  ASSERT_EQ(a2.block->next, NULL);
  ASSERT_EQ(a3.block->next, a1.block);

  ASSERT_EQ(test_free(a1.ptr), a0.full_size + a1.full_size);
  ASSERT_EQ(a0.block->next, NULL);
  ASSERT_EQ(a1.block->next, NULL);
  ASSERT_EQ(a2.block->next, NULL);
  ASSERT_EQ(a3.block->next, NULL);
}

UTEST(malloc_tests, divide_and_consolidate) {
  // reset_context_state();
  // uint8_t heap[128];
  // trigger_supervisor_call_fake.custom_fake = process_syscall_sbrk;
  // context.result = heap;
  // char *ptr = sut_malloc(sizeof(char));
  // memory_block *block = (memory_block *)heap;
  // *ptr = 'a';
  // ASSERT_EQ(context.number, sys_sbrk);
  // ASSERT_EQ(block->size, 16);
  // ASSERT_EQ(block->used, 1);
  // ASSERT_EQ(block->next, NULL);
  // ASSERT_EQ(*((char *)(&heap) + alignof(max_align_t)), 'a');

  // context.result = heap + alignof(max_align_t) * 2;
  // int *ptr2 = sut_malloc(sizeof(int));
  // memory_block *block2 = (memory_block *)(context.result);
  // *ptr2 = 0xcafebabe;
  // ASSERT_EQ(context.number, sys_sbrk);
  // ASSERT_EQ(block2->size, 16);
  // ASSERT_EQ(block2->used, 1);
  // ASSERT_EQ(block->next, block2);
  // ASSERT_EQ(block2->next, NULL);

  // int *data = (int *)(heap + alignof(max_align_t) * 3);
  // ASSERT_EQ(*(int *)&heap[alignof(max_align_t) * 3], 0xcafebabe);

  // context.result = heap + alignof(max_align_t) * 4;
  // char *ptr3 = sut_malloc(sizeof(char) * 24);
  // memory_block *block3 = (memory_block *)(context.result);
  // ASSERT_EQ(block3->size, 32);
  // ASSERT_EQ(block3->used, 1);
  // ASSERT_EQ(block2->next, block3);
  // ASSERT_EQ(block3->next, NULL);

  // const char *msg = "Hello, World!";
  // memcpy(ptr3, msg, strlen(msg) + 1);
  // char *data_str = (char *)(heap + alignof(max_align_t) * 5);
  // ASSERT_STREQ(data_str, msg);
  // int release_size = -(block3->size + alignof(max_align_t));
  // context.number = 0;
  // sut_free(ptr3);
  // ASSERT_EQ(context.number, sys_sbrk);
  // ASSERT_EQ(context.size, release_size);
  // ASSERT_EQ(block2->next, NULL);
  // context.number = 0;
  // sut_free(ptr);
  // // can't be removed because it's not the last block
  // ASSERT_EQ(context.number, 0);
  // ASSERT_EQ(block->used, 0);
  // ASSERT_EQ(block->size, alignof(max_align_t));
  // ASSERT_EQ(block->next, block2);
  // // root -> block(free) -> block2(used)

  // // if we allocate the same size as the released block, it should be reused
  // context.number = 0;
  // int *ptr4 = (int *)sut_malloc(sizeof(int));
  // // can't be removed because it's not the last block
  // ASSERT_EQ(context.number, 0);
  // ASSERT_EQ(block->used, 1);
  // ASSERT_EQ(block->size, alignof(max_align_t));
  // ASSERT_EQ(block->next, block2);
  // ASSERT_EQ(block2->next, NULL);

  // sut_free(ptr4);
  // ASSERT_EQ(context.number, 0);
  // ASSERT_EQ(block->used, 0);
  // ASSERT_EQ(block->size, alignof(max_align_t));
  // ASSERT_EQ(block->next, block2);

  // sut_free(ptr2);
  // ASSERT_EQ(context.number, sys_sbrk);
  // ASSERT_EQ(block->used, 0);
  // ASSERT_EQ(block->next, NULL);
  // ASSERT_EQ(block2->next, NULL);
  // ASSERT_EQ(block3->next, NULL);
}
