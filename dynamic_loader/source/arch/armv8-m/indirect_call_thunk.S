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

.thumb
.syntax unified
.cpu cortex-m33

/* Per-process function-pointer thunk template (16 B), copied per fn-pointer
 * slot. A function pointer on YasOS is the address of one of these: it swaps
 * to the callee's R9 and tail-jumps, so the callee returns straight to the
 * original caller.
 *
 *   +0  ldr.w r9, [pc, #4]   -> r9 = the callee's GOT base at +8
 *   +4  ldr.w pc, [pc, #4]   -> branch to the callee address at +12
 *   +8  .word r9             (patched by the loader)
 *   +12 .word fn             (patched by the loader; Thumb bit set)
 *
 * Both loads are literal loads off the PC (Align(PC,4)+4 = the word two
 * behind each instruction), so the slot only has to be word-aligned. The
 * earlier 20 B head reached a shared tail in kernel flash through an
 * `addw ip; ldr.w pc,[pc]; .word tail` sequence and the tail did the two
 * loads and a `bx ip`: one branch and one instruction more per call, and 4 B
 * more per slot, for nothing the two-load form does not do.
 *
 * It MUST NOT touch SP. It once did `push {r4, lr}` to restore the caller's
 * R9 after a BLX, and that push moved every stack-passed argument 8 bytes out
 * from under the callee (gcc-torture nestfunc-2, seven arguments). Restoring
 * R9 is the caller's job anyway: the compiler reloads it after every call
 * that can leave the module (arm-thumb-gen.c). */
.global indirect_call_thunk_template_start
.thumb_func
.type indirect_call_thunk_template_start, %function
indirect_call_thunk_template_start:
    ldr.w r9, [pc, #4]
    ldr.w pc, [pc, #4]
    .word 0xffffffff
    .word 0xffffffff

.global indirect_call_thunk_template_size
indirect_call_thunk_template_size: .word . - indirect_call_thunk_template_start
