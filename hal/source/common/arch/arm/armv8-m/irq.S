/*
 Copyright (c) 2025 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

@ .syntax unified
@ .arch armv7-m

@     .macro SAVE_CONTEXT r 
@     clrex
@     mrs \r, PSP
@     stmia \r!, {r4-r11}
@     .endm

@     .macro RESTORE_CONTEXT r
@     ldmia \r!, {r4-r11}
@     msr PSP, \r
@     .endm

@ .thumb_func
@ .type irq_svcall, %function
@ .global irq_svcall
@ irq_svcall:
@     push {lr} // push lr on master stack
@     /* Save context on process stackr*/
@     SAVE_CONTEXT r0
@     push {r0}

@     ldr r1, [r0, #36]
@     ldr r2, [r0, #40]
@     ldr r0, [r0, #32]
@     bl os_systemcall 

@     pop {r0}
@     /* Restore context */
@     RESTORE_CONTEXT r0

@     /* Return from interrupt */
@     pop {pc} 