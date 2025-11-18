//
//  context_switch.s
//
//  Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
//  This program is free software: you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation, either version
//  3 of the License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be
//  useful, but WITHOUT ANY WARRANTY; without even the implied
//  warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General
//  Public License along with this program. If not, see
//  <https://www.gnu.org/licenses/>.
//

.syntax unified
.cpu cortex-m33
.thumb

#include "libs/libc/sys/syscall_ids.h"

// This functionality should be called from PendSV IRQ,
// thank's to that we are on MSP with privilege mode
.global switch_to_next_task
.thumb_func
switch_to_next_task:
  // call scheduler to configure next task for the execution
  push {lr}
  bl process_set_next_task
  push {r0-r1}
  bl get_stack_bottom
  msr psplim, r0
  pop {r0-r1}

  // load task context
  bl arm_load_registers_from_stack
  pop {pc}

// r0 - address of the stack to load registers from
.global arm_load_registers_from_stack
.thumb_func
arm_load_registers_from_stack:
  push {lr}
  push {r0}
  bl process_is_current_using_fpu
  pop {r1}
  ldmia r1!, {r2, r4-r12}
  cmp r0, #0
  beq load_no_fpu
  vldmia r1!, {s16-s31}
load_no_fpu:
  msr psp, r1
  mov r0, r2
  pop {pc}

// r0 - address LR to return to
// r1 - 1 if FPU registers should be stored, 0 otherwise
.global arm_store_registers_on_stack
.thumb_func
arm_store_registers_on_stack:
  push {lr}
  mov r2, r0
  mrs r0, psp
  cmp r1, #0
  beq store_no_fpu
  vstmdb r0!, {s16-s31}
store_no_fpu:
  stmdb r0!, {r2, r4-r12}
  bl update_stack_pointer
  pop {pc}



// r0 - value for LR to return to
.global store_and_switch_to_next_task
.thumb_func
store_and_switch_to_next_task:
  push {r4, lr}
  // let's check if fpu is used by current task
  tst lr, #0x10
  ite eq
  moveq r1, #1
  movne r1, #0
  cpsid i // better to not interrupt that operation from nested IRQ
  bl arm_store_registers_on_stack
  bl switch_to_next_task
  cpsie i
  pop {r4, pc}

.global switch_to_the_next_task
.thumb_func
switch_to_the_next_task:
  push {r4, lr}
  cpsid i // better to not interrupt that operation from nested IRQ
  bl switch_to_next_task
  cpsie i
  pop {r4, pc}

.global irq_svcall
.thumb_func
irq_svcall:
  // vfork must store non mangled context first
  cmp r0, #SYS_VFORK_ID
  bne check_if_start_root
  push {r0, r1, r2, lr}
  push {lr}
  bl process_is_current_using_fpu
  mov r1, r0
  pop {r0}
  bl arm_store_registers_on_stack
  pop {r0, r1, r2, lr}
  b call_svcall
check_if_start_root:
  cmp r0, #1
  bne call_svcall
  mov r1, sp
call_svcall:
  push {r0, lr}
  bl _irq_svcall
  pop {r0, pc}

.global switch_to_main_task
.thumb_func:
switch_to_main_task:
  msr msp, r0
  cmp r1, #1
  bne switch_no_fpu
  ldr r0, =0xffffffe9
  b return_to_main_task
switch_no_fpu:
  ldr r0, =0xfffffff9
return_to_main_task:
  bx r0

.global irq_pendsv
.thumb_func
irq_pendsv:
  mov r0, lr
  bl do_context_switch
  bx r0

.global switch_to_the_first_task
.thumb_func
switch_to_the_first_task:
  bl switch_to_next_task
  bx r0