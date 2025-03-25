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
  struct memory_block *prev;
} memory_block;

const size_t memory_block_size =
    (sizeof(memory_block) + alignof(max_align_t) - 1) &
    ~(alignof(max_align_t) - 1);

void process_syscall_sbrk(int number, const void *args, void *result,
                          optional_errno *err) {
  context.number = number;
  context.size = *(intptr_t *)args;
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
      .block = (memory_block *)((void *)result - memory_block_size),
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

UTEST_F(malloc_tests, divide_and_consolidate) {
  uint8_t heap[512];
  trigger_supervisor_call_fake.custom_fake = process_syscall_sbrk;

  allocation_metadata a0 = test_allocate(sizeof(char) * 32, heap);
  char *ptr0 = (char *)a0.ptr;
  ASSERT_EQ(context.number, sys_sbrk);
  ASSERT_EQ(a0.block->size, 32);
  ASSERT_EQ(a0.block->used, 1);
  ASSERT_EQ(a0.block->next, NULL);

  allocation_metadata a1 =
      test_allocate(sizeof(char) * 32, heap + a0.full_size);
  char *ptr1 = (char *)a1.ptr;
  ASSERT_EQ(context.number, sys_sbrk);
  ASSERT_EQ(a1.block->size, 32);
  ASSERT_EQ(a1.block->used, 1);
  ASSERT_EQ(a1.block->next, NULL);

  allocation_metadata a2 =
      test_allocate(sizeof(char) * 32, heap + a0.full_size + a1.full_size);
  char *ptr2 = (char *)a2.ptr;
  ASSERT_EQ(context.number, sys_sbrk);
  ASSERT_EQ(a2.block->size, 32);
  ASSERT_EQ(a2.block->used, 1);
  ASSERT_EQ(a2.block->next, NULL);

  allocation_metadata a3 = test_allocate(
      sizeof(char) * 32, heap + a0.full_size + a1.full_size + a2.full_size);
  char *ptr3 = (char *)a3.ptr;
  ASSERT_EQ(context.number, sys_sbrk);
  ASSERT_EQ(a3.block->size, 32);
  ASSERT_EQ(a3.block->used, 1);
  ASSERT_EQ(a3.block->next, NULL);

  ASSERT_EQ(a0.block->next, a1.block);
  ASSERT_EQ(a1.block->next, a2.block);
  ASSERT_EQ(a2.block->next, a3.block);

  ASSERT_EQ(test_free(a2.ptr), 0);
  // release the block in the middle
  ASSERT_EQ(a0.block->next, a1.block);
  ASSERT_EQ(a1.block->next, a2.block);
  ASSERT_EQ(a2.block->next, a3.block);
  ASSERT_EQ(a3.block->next, NULL);

  // release left block to consolidate right
  ASSERT_EQ(test_free(a1.ptr), 0);
  // release the block in the middle
  ASSERT_EQ(a0.block->next, a1.block);
  ASSERT_EQ(a1.block->next, a3.block);
  ASSERT_EQ(a3.block->next, NULL);

  ASSERT_TRUE(a0.block->used);
  ASSERT_FALSE(a1.block->used);
  ASSERT_FALSE(a2.block->used);
  ASSERT_TRUE(a3.block->used);

  // 3 blocks with 32 bytes each + single memory metadata block
  ASSERT_EQ(test_free(a3.ptr), a1.full_size + a2.full_size + a3.full_size);
  ASSERT_EQ(a3.block->next, NULL);

  ASSERT_EQ(test_free(a0.ptr), a0.full_size);
  ASSERT_EQ(a0.block->next, NULL);

  ASSERT_FALSE(a0.block->used);
  ASSERT_FALSE(a1.block->used);
  ASSERT_FALSE(a2.block->used);
  ASSERT_FALSE(a3.block->used);
}
