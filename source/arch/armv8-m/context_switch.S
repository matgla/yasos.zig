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
  push {r4, lr}
  bl get_next_task
  push {r0-r1}
  bl get_stack_bottom
  msr psplim, r0
  pop {r0-r1}

  // load task context
  bl load_context
  pop {r4, pc}

.global reload_current_task
.thumb_func
reload_current_task:
  push {lr}
  // call scheduler to configure next task for the execution
  bl get_current_task
  // load task context
  ldmia r0!, {r1, r4-r12}
  vldmia r0!, {s16-s31}
  msr psp, r0
  pop {pc}

.global load_context
.thumb_func
load_context:
  mov r1, r0
  ldmia r1!, {r0, r4-r12}
  vldmia r1!, {s16-s31}
  msr psp, r1
  cpsie i
  bx lr

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

.global push_registers_on_stack
.thumb_func
push_registers_on_stack:
  push {lr}
  vstmdb r0!, {s16-s31}
  stmdb r0!, {r1, r4-r12}
  push {r0, r4}
  bl update_stack_pointer
  pop {r0, r4}
  pop {pc}


.global store_and_switch_to_next_task
.thumb_func
store_and_switch_to_next_task:
  push {r4, lr}
  cpsid i // better to not interrupt that operation from nested IRQ
  mov r1, r0
  mrs r0, psp
  vstmdb r0!, {s16-s31}
  stmdb r0!, {r1, r4-r12}

  bl update_stack_pointer
  bl switch_to_next_task
  pop {r4, pc}

//.global store_kernel_context_and_switch
//.thumb_func
//store_kernel_context_and_switch:
  // push {r4, lr}
  // cpsid i // better to not interrupt that operation from nested IRQ
  // // how to store msp too?
  // mrs r0, psp
  // vstmdb r0!, {s16-s31}
  // stmdb r0!, {r4-r12, lr}

  // bl update_stack_pointer
  // bl switch_to_next_task
  // pop {r4, pc}

.global switch_to_the_next_task
.thumb_func
switch_to_the_next_task:
  push {r4, lr}
  cpsid i // better to not interrupt that operation from nested IRQ
  bl switch_to_next_task
  pop {r4, pc}

.global irq_svcall
.thumb_func
irq_svcall:
  push {r0, lr}
  bl _irq_svcall
  mrs r1, psp
  str r0, [r1]
  pop {r0, pc}

 //  cmp r0, #16
  // bne check_if_start_root
  // push {r0, r1, r2, lr}
  // mrs r0, psp
  // mov r1, lr
  // vstmdb r0!, {s16-s31}
  // stmdb r0!, {r1, r4-r12}
  // bl update_stack_pointer
  // pop {r0, r1, r2, lr}
  // b call_svcall
// check_if_start_root:
  // cmp r0, #1
  // bne call_svcall
  // ldr r0, =sp_call
  // str sp, [r0]
  // tst lr, #0x10
  // bne omit_fpu
  // ldr r0, =sp_call_fpu
  // push {r1}
  // mov r1, #1
  // str r1, [r0]
  // pop {r1}
// omit_fpu:
  // mov r0, 1
// call_svcall:
  // push {r0, lr}
  // bl _irq_svcall
  // pop {r1, pc}

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
  mrs r1, CONTROL
  orr r1, r1, #3
  msr CONTROL, r1
  isb
  bx r0