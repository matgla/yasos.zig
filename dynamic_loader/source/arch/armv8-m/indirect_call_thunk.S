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

/* Shared dispatch tail — assembled ONCE into kernel flash and pointed at by
 * every per-process head, so the per-process thunk drops from 28 B to 20 B.
 * Entry: ip = &descriptor (the {r9, fn} word pair in the per-process head).
 * It swaps to the callee's R9 and tail-jumps, so the callee returns straight to
 * the original caller.
 *
 * It MUST NOT touch SP. This used to `push {r4, lr}` so it could restore the
 * caller's R9 after a BLX, and that push moved every stack-passed argument 8
 * bytes out from under the callee. Calls of up to four arguments are unaffected
 * (r0-r3), which is why it survived so long; gcc-torture's nestfunc-2 calls a
 * function pointer with *seven*, and its callee read the saved r4/lr as two of
 * them -- producing a garbage result and, once that value was used as a
 * pointer, a HardFault. The failure looked layout-dependent because what the
 * callee read at the displaced offsets was whatever the caller's frame happened
 * to hold.
 *
 * Restoring R9 here was never this stub's job: the compiler already brackets
 * every PIC indirect call with its own save/restore (arm-thumb-gen.c emits
 * `str.w r9,[sp,#n]` before the BLX and `ldr.w r9,[sp,#n]` after it), so the
 * old sequence was redundant as well as harmful. Tail-jumping is also shorter:
 * three instructions and no stack traffic per indirect call. */
.global indirect_call_shared_tail
.thumb_func
.type indirect_call_shared_tail, %function
indirect_call_shared_tail:
    ldr.w r9, [ip]          /* r9 = descriptor[0] = callee GOT base */
    ldr.w ip, [ip, #4]      /* ip = descriptor[1] = callee address  */
    bx ip                   /* tail jump: SP and LR untouched */

/* Per-process head template (20 B), copied per fn-pointer slot. Layout:
 *   +0  addw ip, pc, #8     -> ip = &descriptor (the r9 word at +12)
 *   +4  ldr.w pc, [pc]      -> branch to the shared tail (loaded from +8;
 *                              an indirect load, so the 256 MiB RAM->flash gap
 *                              that rules out a direct b.w is a non-issue)
 *   +8  .word tail          -> &indirect_call_shared_tail, resolved at link
 *                              time and copied verbatim (no per-slot patch)
 *   +12 .word r9            -> callee GOT base (patched by the loader)
 *   +16 .word fn            -> callee address  (patched by the loader) */
.global indirect_call_thunk_template_start
.thumb_func
.type indirect_call_thunk_template_start, %function
indirect_call_thunk_template_start:
    addw ip, pc, #8
    ldr.w pc, [pc]
    .word indirect_call_shared_tail
    .word 0xffffffff
    .word 0xffffffff

.global indirect_call_thunk_template_size
indirect_call_thunk_template_size: .word . - indirect_call_thunk_template_start
