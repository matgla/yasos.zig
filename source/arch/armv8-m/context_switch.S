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
  ldmia r0!, {r1} // is fpu used
  ldmia r0!, {r2, r4-r12}
  cmp r1, #0
  beq load_no_fpu
  vldmia r0!, {s16-s31}
load_no_fpu:
  msr psp, r0
  mov r0, r2
  pop {pc}

// r0 - address LR to return to
// r1 - 1 if FPU registers should be stored, 0 otherwise
.global arch_store_registers_on_stack
.thumb_func
arch_store_registers_on_stack:
  push {lr}
  mov r2, r0
  mrs r0, psp
  cmp r1, #0
  beq store_no_fpu
  vstmdb r0!, {s16-s31}
store_no_fpu:
  stmdb r0!, {r2, r4-r12}
  stmdb r0!, {r1}
  bl update_stack_pointer
  pop {pc}



// r0 - value for LR to return to
.global store_and_switch_to_next_task
.thumb_func
store_and_switch_to_next_task:
  push {r4, lr}
  // let's check if fpu is used by current task
  bl arch_store_registers_on_stack
  bl switch_to_next_task
  pop {r4, pc}

.global switch_to_the_next_task
.thumb_func
switch_to_the_next_task:
  push {lr}
  bl switch_to_next_task
  pop {pc}

.global dispatch_syscall
.thumb_func
dispatch_syscall:
  push {r0, r1}
  push {r0-r3}
  bl unblock_context_switch
  pop {r0-r3}
  bl _irq_svcall
  bl block_context_switch
  mov r0, #0
  svc #1 // this pushes another context

// r0 - syscall number
// r1 - arg pointer
// r2 - syscall result pointer
// syscall number 0 is internal syscall to return to user mode
.global irq_svcall
.thumb_func
irq_svcall:
  push {r0-r4, lr}
  bl block_context_switch
  pop {r0-r4, lr}
  cmp r0, #0
  bne process_syscall_entry
  // process syscall exit
  @ mrs r0, control
  @ orr r0, r0, #1
  @ msr control, r0
  mrs r2, psp
    // let's check if fpu is used by current task
  tst lr, #0x10
  bne process_syscall_return_without_fpu
  add r2, r2, #68 // remove fpu registers from stack
process_syscall_return_without_fpu:
  add r2, r2, #32 // skip general purpose registers
  ldmia r2!, {r0, r3}
  add r2, r2, #4
  ldmia r2!, {r1}
  msr psp, r2
  bx r1

process_syscall_entry:
  push {r4, r5, r6}
  mrs r4, psp
  ldr r6, [r4, #28] // get psr
  ldr r3, =return_from_syscall
  ldr r5, =dispatch_syscall
  stmdb r4!, {r0, lr}
  stmdb r4!, {r3, r5, r6}
  stmdb r4!, {r0-r3, r12}
  msr psp, r4
  mrs r4, control
  bic r4, r4, #1
  msr control, r4
  ldr r3, =0xfffffffd
  pop {r4, r5, r6}
  bx r3 // we are taking back context from 134
.thumb_func
return_from_syscall:
  @ we are no longer in exception, restore stack manually
  bl unblock_context_switch
  pop {r1, pc}

.global arch_get_stack_pointer
.thumb_func
arch_get_stack_pointer:
  mov r0, sp
  bx lr


.global switch_to_main_task
.thumb_func:
switch_to_main_task:
  mrs r0, control
  bic r0, r0, #3
  msr control, r0
  pop {pc}

.global irq_pendsv
.thumb_func
irq_pendsv:
  push {lr}
  tst lr, #0x10
  ite eq
  moveq r0, #1
  movne r0, #0
  bl do_context_switch
  cmp r0, #0
  pop {r2}
  beq pendsv_exit
  bx r2
pendsv_exit:
  b switch_to_main_task


.global switch_to_the_first_task
.thumb_func
switch_to_the_first_task:
  push {lr}
  bl switch_to_next_task
  mrs r1, control
  orr r1, r1, #3 // unprivileged + psp
  msr control, r1
  bx r0


// r0 - pid
// r1 - sp
// r2 - lr
.global process_get_back_to_parent_vfork
.thumb_func
process_get_back_to_parent_vfork:
  mov sp, r1
  bx r2



// r0 - pointer to child r11 value
// r1 - pointer to child got value
// r2 - pointer to child return
.global process_vfork_child
.thumb_func
process_vfork_child:
  push {r4-r12, lr}
  mov r3, sp
  mov r11, r0
  push {r1, r2} // r9 for child, other for alignment
  ldr r0, =process_vfork_back_here
  mov r1, r3
  bl arch_store_vfork_back_point
  ldr r1, [sp, #4]
  mov r0, #0
  bx r1

.thumb_func
process_vfork_back_here:
  pop {r4-r12, pc}
