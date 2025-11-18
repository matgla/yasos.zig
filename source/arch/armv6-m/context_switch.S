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
.arch armv6-m
.thumb

// armv6-m do not have FPU, so only CPU registers must be stored
// callee saved registers are r4-r11 according to aapcs

// This functionality should be called from PendSV IRQ,
// thank's to that we are on MSP with privilege mode
.global switch_to_next_task
.thumb_func
switch_to_next_task:
  // call scheduler to configure next task for the execution
  bl process_set_next_task
  // load task context
  ldmia r0!, {r3-r7}
  mov r8, r3
  mov r9, r4
  mov r10, r5
  mov r11, r6
  mov r1, r7
  ldmia r0!, {r4-r7}
  msr psp, r0
  cpsie i
  push {r0, r1}
  bl unlock_pendsv_spinlock
  pop {r0, r1}
  bx r1

.global push_return_address
.thumb_func
push_return_address
push {r0, lr}
bx lr

.global store_and_switch_to_next_task
.thumb_func
store_and_switch_to_next_task:
  cpsid i // better to not interrupt that operation from nested IRQ
  mrs r0, psp
  subs r0, r0, #0x10
  stm r0!, {r4-r7}
  mov r3, r8
  mov r4, r9
  mov r5, r10
  mov r6, r11
  mov r7, lr
  subs r0, r0, #0x24
  stm r0!, {r3-r7}
  subs r0, r0, #0x14

  bl update_stack_pointer
  b switch_to_next_task

