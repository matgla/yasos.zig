// 
// vector_table.S 
// 
// Copyright (C) 2023 Mateusz Stadnik <matgla@live.com>
// 
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
// 
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
// 
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.

.syntax unified 
.arch armv6-m
.cpu cortex-m0plus
.thumb 

#define PPB_BASE 0xe0000000
#define M0PLUS_VTOR_OFFSET 0x0000ed08

.section .vectors, "ax"
.align 2 

.global __vector_table
__vector_table:
  .word __stack_top__ 
  .word _start
  .word irq_nmi 
  .word irq_hard_fault
  .word irq_reserved 
  .word irq_reserved 
  .word irq_reserved 
  .word irq_reserved 
  .word irq_reserved 
  .word irq_reserved 
  .word irq_reserved 
  .word irq_svcall 
  .word irq_reserved 
  .word irq_reserved 
  .word irq_pendsv
  .word irq_systick
  .word irq0
  .word irq1
  .word irq2 
  .word irq3
  .word irq4
  .word irq5
  .word irq6
  .word irq7
  .word irq8
  .word irq9
  .word irq10
  .word irq11
  .word irq12 
  .word irq13
  .word irq14
  .word irq15
  .word irq16
  .word irq17
  .word irq18
  .word irq19
  .word irq20
  .word irq21
  .word irq22 
  .word irq23
  .word irq24
  .word irq25
  .word irq26
  .word irq27
  .word irq28
  .word irq29
  .word irq30
  .word irq31


/* Weak symbol since it will be overriden if needed */
.macro declare_irq_handler_breakpoint name 
.weak \name
.type \name,%function
.thumb_func 
\name:
  bkpt #0 
.endm

declare_irq_handler_breakpoint irq_reserved
declare_irq_handler_breakpoint irq_nmi 
declare_irq_handler_breakpoint irq_hard_fault
declare_irq_handler_breakpoint irq_svcall 
declare_irq_handler_breakpoint irq_pendsv 
declare_irq_handler_breakpoint irq_systick
declare_irq_handler_breakpoint irq0
declare_irq_handler_breakpoint irq1
declare_irq_handler_breakpoint irq2
declare_irq_handler_breakpoint irq3
declare_irq_handler_breakpoint irq4
declare_irq_handler_breakpoint irq5
declare_irq_handler_breakpoint irq6
declare_irq_handler_breakpoint irq7
declare_irq_handler_breakpoint irq8
declare_irq_handler_breakpoint irq9
declare_irq_handler_breakpoint irq10
declare_irq_handler_breakpoint irq11
declare_irq_handler_breakpoint irq12
declare_irq_handler_breakpoint irq13
declare_irq_handler_breakpoint irq14
declare_irq_handler_breakpoint irq15
declare_irq_handler_breakpoint irq16
declare_irq_handler_breakpoint irq17
declare_irq_handler_breakpoint irq18
declare_irq_handler_breakpoint irq19
declare_irq_handler_breakpoint irq20
declare_irq_handler_breakpoint irq21
declare_irq_handler_breakpoint irq22
declare_irq_handler_breakpoint irq23
declare_irq_handler_breakpoint irq24
declare_irq_handler_breakpoint irq25
declare_irq_handler_breakpoint irq26
declare_irq_handler_breakpoint irq27
declare_irq_handler_breakpoint irq28
declare_irq_handler_breakpoint irq29
declare_irq_handler_breakpoint irq30
declare_irq_handler_breakpoint irq31

.global __unhandled_user_irq
.type __unhandled_user_irq,%function
.thumb_func 
__unhandled_user_irq:
  mrs r0, ipsr
  subs r0, #16
  bkpt #0 // irq number in r0

.global _start
.type _start,%function
.thumb_func 
_start:
  ldr r1, =__vector_table 
  ldr r0, =(PPB_BASE + M0PLUS_VTOR_OFFSET)
  str r1, [r0]
  ldr r1, =crt_init
  blx r1
  ldr r1, =main 
  blx r1 
