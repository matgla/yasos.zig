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
  ldmia r0!, {r1, r4-r12}
  vldmia r0!, {s16-s31}
  msr psp, r0
  cpsie i
  push {r0, r1}
  bl unlock_pendsv_spinlock
  pop {r0, r1}
  bx r1

.global store_and_switch_to_next_task
.thumb_func
store_and_switch_to_next_task:
  cpsid i // better to not interrupt that operation from nested IRQ
  mrs r0, psp 
  mov r1, lr
  vstmdb r0!, {s16-s31}
  stmdb r0!, {r1, r4-r12}
  
  bl update_stack_pointer
  b switch_to_next_task

.global context_switch_push_registers_to_stack
.thumb_func
context_switch_push_registers_to_stack:
  vstmdb r0!, {s16-s31}
  stmdb r0!, {r1, r4-r12}
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