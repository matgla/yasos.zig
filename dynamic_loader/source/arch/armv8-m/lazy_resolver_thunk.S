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

/*
 * Lazy resolver thunk template for PLT+GOT lazy binding.
 *
 * When a GOT entry has not been resolved yet, the PLT stub jumps here.
 * At entry:
 *   r0-r3  = original caller arguments
 *   r9     = current module's GOT base (set by PLT stub from GOT[i].base_register)
 *   lr     = return address in original caller (PLT uses BX, not BL)
 *   ip     = this thunk address (loaded from GOT[i].symbol_offset by PLT)
 *
 * The thunk:
 *   1. Saves all argument registers and lr
 *   2. Calls the lazy resolver with a pointer to LazyBindingInfo
 *   3. The resolver resolves the symbol, patches GOT[i], returns {addr, r9}
 *   4. Restores arguments and tail-calls the resolved function
 *
 * Template data (patched by the loader):
 *   offset +24: pointer to LazyBindingInfo struct
 *   offset +28: pointer to lazy_resolve function
 *
 * Total size: 32 bytes
 */

.thumb
.syntax unified
.cpu cortex-m33

.global lazy_resolver_thunk_template_start
.thumb_func
.type lazy_resolver_thunk_template_start, %function
lazy_resolver_thunk_template_start:
    push  {r0-r3}             /* save argument registers (SP -= 16) */
    push  {r4, lr}            /* save r4 and return address (SP -= 8) */
    /* Stack layout: [r4, lr, r0, r1, r2, r3] from SP upward */
    ldr   r0, lazy_info_ptr   /* arg0 = pointer to LazyBindingInfo */
    ldr   r4, resolver_fn     /* load lazy_resolve function address */
    blx   r4                  /* call lazy_resolve(info) -> r0=addr, r1=target_r9 */
    mov   ip, r0              /* save resolved function address in ip */
    mov   r9, r1              /* set R9 to target module's GOT base */
    pop   {r4}                /* restore r4 (pops r4_saved from top) */
    pop   {r0}                /* pop saved lr into r0 */
    mov   lr, r0              /* restore lr = original return address */
    pop   {r0-r3}             /* restore original arguments */
    bx    ip                  /* tail-call the resolved function */
    .align 2
lazy_info_ptr:  .word 0xffffffff
resolver_fn:    .word 0xffffffff

.global lazy_resolver_thunk_template_size
lazy_resolver_thunk_template_size: .word . - lazy_resolver_thunk_template_start
