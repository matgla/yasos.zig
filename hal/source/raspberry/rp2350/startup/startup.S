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
.cpu cortex-m33
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
  .word irq_memmanage
  .word irq_busfault
  .word irq_usagefault
  .word irq_securefault
  .word irq_reserved
  .word irq_reserved
  .word irq_reserved
  .word irq_svcall
  .word irq_debugmonitor
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
  .word irq32
  .word irq33
  .word irq34
  .word irq35
  .word irq36
  .word irq37
  .word irq38
  .word irq39
  .word irq40
  .word irq41
  .word irq42
  .word irq43
  .word irq44
  .word irq45
  .word irq46
  .word irq47
  .word irq48
  .word irq49
  .word irq50
  .word irq51


/* Weak symbol since it will be overriden if needed */
.macro declare_irq_handler_breakpoint name
.weak \name
.type \name,%function
.thumb_func
\name:
  bkpt #0
.endm

/* Weak symbol since it will be overriden if needed */
.macro declare_irq_handler name
.weak \name
.type \name,%function
.thumb_func
\name:
.endm

declare_irq_handler_breakpoint irq_reserved
declare_irq_handler_breakpoint irq_nmi
declare_irq_handler_breakpoint irq_hard_fault
declare_irq_handler_breakpoint irq_svcall
declare_irq_handler_breakpoint irq_pendsv
declare_irq_handler_breakpoint irq_systick
declare_irq_handler irq0
declare_irq_handler irq1
declare_irq_handler irq2
declare_irq_handler irq3
declare_irq_handler irq4
declare_irq_handler irq5
declare_irq_handler irq6
declare_irq_handler irq7
declare_irq_handler irq8
declare_irq_handler irq9
declare_irq_handler irq10
declare_irq_handler irq11
declare_irq_handler irq12
declare_irq_handler irq13
declare_irq_handler irq14
declare_irq_handler irq15
declare_irq_handler irq16
declare_irq_handler irq17
declare_irq_handler irq18
declare_irq_handler irq19
declare_irq_handler irq20
declare_irq_handler irq21
declare_irq_handler irq22
declare_irq_handler irq23
declare_irq_handler irq24
declare_irq_handler irq25
declare_irq_handler irq26
declare_irq_handler irq27
declare_irq_handler irq28
declare_irq_handler irq29
declare_irq_handler irq30
declare_irq_handler irq31
declare_irq_handler irq32
declare_irq_handler irq33
declare_irq_handler irq34
declare_irq_handler irq35
declare_irq_handler irq36
declare_irq_handler irq37
declare_irq_handler irq38
declare_irq_handler irq39
declare_irq_handler irq40
declare_irq_handler irq41
declare_irq_handler irq42
declare_irq_handler irq43
declare_irq_handler irq44
declare_irq_handler irq45
declare_irq_handler irq46
declare_irq_handler irq47
declare_irq_handler irq48
declare_irq_handler irq49
declare_irq_handler irq50
declare_irq_handler irq51

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
  ldr r1, =__stack_bottom__
  msr msplim, r1
  ldr r1, =__vector_table
  ldr r0, =(PPB_BASE + M0PLUS_VTOR_OFFSET)
  str r1, [r0]
  ldr r1, =crt_init
  blx r1
  ldr r1, =main
  blx r1
  bkpt #0
_loop:
  wfi
  b _loop
