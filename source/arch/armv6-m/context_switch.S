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
switch_to_next_task:
  // call scheduler to configure next task for the execution 
  bl get_next_task
  // load task context 
  ldmia r0!, {r4-r11}
  msr psp, r0
  mov pc, lr 

.global store_and_switch_to_next
store_and_switch_to_next:
  mrs r0, psp 
  stmdb r0!, {r4-r11, lr}
  bl update_stack_pointer
  b switch_to_next_task
  
