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

// This functionality should be called from PendSV IRQ,
// thank's to that we are on MSP with privilege mode
.global switch_to_next_task
.thumb_func
switch_to_next_task:
  // call scheduler to configure next task for the execution 
  bl get_next_task
  // load task context
  b load_context

.global reload_current_task
.thumb_func
reload_current_task:
  // call scheduler to configure next task for the execution 
  bl get_current_task
  // load task context
  b load_context

.global load_context
.thumb_func
load_context: 
  ldmia r0!, {r1, r4-r12}
  vldmia r0!, {s16-s31}
  msr psp, r0
  cpsie i
  bx r1


.global store_and_switch_to_next_task
.thumb_func
store_and_switch_to_next_task:
  cpsid i // better to not interrupt that operation from nested IRQ
  mov r1, r0 
  mrs r0, psp 
  vstmdb r0!, {s16-s31}
  stmdb r0!, {r1, r4-r12}
  
  bl update_stack_pointer
  b switch_to_next_task

.global context_switch_push_registers_to_stack
.thumb_func
context_switch_push_registers_to_stack:
  push {r4}
  mrs r4, psp 
  stmdb r4!, {r0, r1, r2, r3}
  mov r0, r4
  pop {r4} 
  vstmdb r0!, {s16-s31}
  stmdb r0!, {r3, r4-r12}
  bx lr

.global context_switch_get_psp
.thumb_func
context_switch_get_psp:
  mrs r0, psp 
  bx lr

.global get_lr
.thumb_func 
get_lr:
  mov r0, lr

.global context_switch_return_pop_single
.thumb_func
context_switch_return_pop_single:
  mrs r1, psp 
  push {r4}
  ldmia r1!, {r0, r2, r3, r4}
  pop {r4}
  str r2, [r0]
  msr psp, r1
  bx r3 