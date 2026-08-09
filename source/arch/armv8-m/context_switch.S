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

// ─── DCP (RP2350 double coprocessor, CP4) context ───────────────────────────
//
// The FPU needs no help from us: the hardware stacks s0-s15 on exception entry
// and the software frame below carries s16-s31. The DCP is different. It is not
// an FPU -- it holds X, Y and EFD state that no exception entry touches, and a
// double operation is a *sequence* of CP4 instructions (`WXUP;WYUP;ADD0;ADD1;
// NRDD;RDDA` for an add). Preempt one of those six instructions, let the next
// process start its own DCP sequence, and the first resumes on top of foreign
// state: a wrong double result, silently, with no fault.
//
// So when user code may execute DCP sequences (tcc -mfpu=rp2350, i.e.
// CONFIG_BUILD_USERSPACE_HARDWARE_FP on a CONFIG_CPU_HAS_DCP part) the switch
// saves and restores that state. This is the scheduler-side half of the
// "preemptor saves" contract; pico-sdk implements the same save/restore inside
// its __aeabi_* entry points for the interrupt case.
//
// The common case costs one non-engaging peek: PCMP reports whether a sequence
// is actually in flight, and only then are the six state words read. The frame
// slot is fixed-size either way (see SoftwareStoredRegisters in
// source/arch/arm-m/process.zig, which must stay in sync).
//
// Instruction notes, since these are raw coprocessor encodings:
//   PCMP (mrc2 p4,#0,Rt,c0,c0,#1) - peek; bit31 = engaged. Does NOT engage.
//   PXMD / PYMD (mrrc2 p4,#0,..,c8/c9) - peek X / Y. Do NOT engage.
//   REFD (mrrc p4,#0,..,c10) - read EFD. Engaging: also CLEARS the flag, which
//                              is why it comes last in the save.
//   WXMD / WYMD / WEFD (mcrr p4,#0,..,c0/c1/c2) - write back. Engaging, so the
//                              restore leaves the flag set and a second
//                              preemption of the same sequence saves again.
#if YASOS_SAVE_DCP_STATE

// Reserve and fill the DCP slot at the top of the software frame.
// Clobbers r3 and r12; r1 = frame pointer, moved down by 28 bytes.
.macro DCP_SAVE_STATE
  sub r1, r1, #28
  mrc2 p4, #0, r3, c0, c0, #1   // PCMP
  lsrs r3, r3, #31              // engaged -> 0/1, sets Z when not engaged
  str r3, [r1, #24]
  beq 99f
  mrrc2 p4, #0, r3, r12, c8     // PXMD -> X lo/hi
  strd r3, r12, [r1, #0]
  mrrc2 p4, #0, r3, r12, c9     // PYMD -> Y lo/hi
  strd r3, r12, [r1, #8]
  mrrc p4, #0, r3, r12, c10     // REFD -> EFD lo/hi (clears engaged)
  strd r3, r12, [r1, #16]
99:
.endm

// Consume the DCP slot. Clobbers r1, r3 and r12; r0 = frame pointer, moved up
// by 28 bytes.
.macro DCP_RESTORE_STATE
  ldr r1, [r0, #24]
  cmp r1, #0
  beq 98f
  ldrd r3, r12, [r0, #0]
  mcrr p4, #0, r3, r12, c0      // WXMD
  ldrd r3, r12, [r0, #8]
  mcrr p4, #0, r3, r12, c1      // WYMD
  ldrd r3, r12, [r0, #16]
  mcrr p4, #0, r3, r12, c2      // WEFD
98:
  add r0, r0, #28
.endm

#else

.macro DCP_SAVE_STATE
.endm

.macro DCP_RESTORE_STATE
.endm

#endif

// r0 - is fpu used
// r1 - lr to return to
.global switch_to_next_task
.thumb_func
switch_to_next_task:
  // call scheduler to configure next task for the execution
  push {lr, r0} // lr and is fpu
  push {r0, r1} // is fpu and process lr
  bl process_set_next_task // no arguments r0 = next sp
  push {r0, r1}
  bl get_stack_bottom // no arguments - r0 = sp bottom
  msr psplim, r0
  isb
  dsb
  pop {r0, r1}
  pop {r2, r1}
  // load task context
  bl arm_load_registers_from_stack
  pop {pc, r1}

// r0 - address to load from
// r1 - 1 if FPU registers should be loaded, 0 otherwise
.global arm_load_registers_from_stack
.thumb_func
arm_load_registers_from_stack:
  push {lr}
  ldmia r0!, {r1} // is fpu used
  ldmia r0!, {r2, r4-r11}
  cmp r1, #0
  beq load_no_fpu
  vldmia r0!, {s16-s31}
load_no_fpu:
  // The DCP slot sits above the FP registers, so it is read last -- mirroring
  // the save, which writes it first.
  DCP_RESTORE_STATE
  msr psp, r0
  isb
  dsb
  mov r0, r2
  pop {pc}

// r0 - 1 if FPU registers should be stored, 0 otherwise
// r1 - address LR to return to
.global arch_store_registers_on_stack
.thumb_func
arch_store_registers_on_stack:
  push {lr}
  mov r2, r1
  mrs r1, psp
  isb
  // Top of the software frame, so it is pushed before anything else.
  DCP_SAVE_STATE
  cmp r0, #0
  beq store_no_fpu
  vstmdb r1!, {s16-s31}
store_no_fpu:
  stmdb r1!, {r2, r4-r11}
  stmdb r1!, {r0}
  mov r0, r1
  bl update_stack_pointer
  pop {pc}



// r0 - value for LR to return to
.global store_and_switch_to_next_task
.thumb_func
store_and_switch_to_next_task:
  // Use r1 (not r4) as the stack-alignment filler for the saved lr. r4 is a
  // callee-saved register: switch_to_next_task -> arm_load_registers_from_stack
  // loads the INCOMING task's r4-r11, so popping a saved r4 here would clobber
  // the new task's r4 with the outgoing task's value (it then resumes with the
  // wrong r4). r1 is caller-saved and is reloaded from the incoming task's
  // hardware exception frame when the caller does `bx r0`, so clobbering it is
  // harmless; r0 (the incoming EXC_RETURN) is preserved for that `bx r0`.
  push {r1, lr}
  // let's check if fpu is used by current task
  push {r0, r1}
  bl arch_store_registers_on_stack
  pop {r0, r1}
  bl switch_to_next_task
  pop {r1, pc}

.global dispatch_syscall
.thumb_func
dispatch_syscall:
  // this is not in IRQ, so can be interrupted
  push {r7, lr}
  add r7, sp, #0
  @ push {r0, r1}
  bl _irq_svcall
  pop {r7, lr}
  push {r0, r1}
  mov r0, #0
  svc #1 // this pushes another context
  @ pop {r0, r1}
  @ pop {r7, pc}

// r0 - syscall number
// r1 - arg pointer
// r2 - syscall result pointer
// syscall number 0 is internal syscall to return to user mode
.global irq_svcall
.thumb_func
irq_svcall:
  // this is processed in irq
  cmp r0, #1
  beq process_syscall_unblock_context_switch
  cmp r0, #0
  bne process_syscall_fast_check
  mrs r2, psp
  isb
    // let's check if fpu is used by current task
  tst lr, #0x10
  bne process_syscall_return_without_fpu
  // 72 == the FP part of an extended exception frame: s0-s15 (64) + FPSCR (4)
  // + the reserved word (4). Must match HardwareStoredRegisters in
  // source/arch/arm-m/process.zig, which ends s0..s15, fpscr, aligner. This
  // read 68 and so left PSP one word low whenever the frame really was
  // extended, shifting every subsequent pop by 4 bytes.
  add r2, r2, #72 // remove fpu registers from stack
process_syscall_return_without_fpu:
  add r2, r2, #32 // skip general purpose registers
  ldmia r2!, {r0, r3}
  ldmia r2!, {r3, lr}
  msr psp, r2
  isb
  // The syscall ran privileged (process_syscall_entry cleared nPRIV); restore
  // the resumed process's privilege level so an unprivileged process does not
  // continue running privileged after returning from a syscall.
  push {r0, lr}
  bl apply_current_privilege
  pop {r0, lr}
  bx lr
  //ldmia r2!, {r1}
  // msr psp, r2
  // dsb
  // isb


// Fast path: a syscall whose handler never blocks/schedules can run directly in
// the handler (already privileged) and exception-return to the user. The result
// is written through the out pointer (r2), so the user frame needs no patching;
// CONTROL.nPRIV is left untouched, so the thread resumes at its prior privilege.
// r0 = syscall number, r1 = arg pointer, r2 = out pointer, lr = EXC_RETURN.
process_syscall_fast_check:
  push {r0-r3, lr}
#if YASOS_PERF_SYSCALL_STAMP
  // Stamp DWT_CYCCNT for the syscall profiler before anything else runs. This
  // is the only point that sees the cost of exception entry and of the
  // trampoline the slow path is about to build; _irq_svcall can only time
  // itself. r1/r2 are restored by the pop below, so nothing user-visible is
  // clobbered. Compiled in only with CONFIG_INSTRUMENTATION_PERF_PROFILING.
  ldr r1, =0xE0001004     // DWT_CYCCNT
  ldr r1, [r1]
  ldr r2, =perf_svc_entry_cycles
  str r1, [r2]
#endif
  bl syscall_is_fast      // r0(number) -> r0 (1 fast, 0 otherwise)
  cmp r0, #0
  pop {r0-r3, lr}         // ldmia preserves the condition flags
  beq process_syscall_entry
  // fast: dispatch in handler mode, args (r0-r2) already in place
  push {r0, lr}           // r0 for 8-byte alignment; lr = EXC_RETURN
  bl _irq_svcall
  pop {r0, lr}
  bx lr                   // exception return to user; nPRIV unchanged

process_syscall_entry:
  push {r4, r5, r6, r7}
  mrs r4, psp
  isb
  ldr r6, [r4, #28] // get psr
  ldr r3, =return_from_syscall
  ldr r5, =dispatch_syscall
  // simulated exception frame
  stmdb r4!, {r0, lr}
  stmdb r4!, {r3, r5, r6}
  stmdb r4!, {r0-r3, r12}
  msr psp, r4
  isb
  mrs r4, control
  isb
  bic r4, r4, #1
  msr control, r4
  isb
  // FType=1 (no FP frame) regardless of how we were entered. The user's `svc`
  // may well have been taken from FP context (EXC_RETURN 0xffffffed), so this
  // deliberately breaks the FType pairing the FPU's lazy stacking relies on:
  // LSPACT would stay set with FPCAR still aimed at the user frame, which the
  // process then reuses as ordinary stack, and the deferred save would land 17
  // words on top of live data. That is why the kernel turns lazy stacking off
  // at init -- see disable_lazy_fp_stacking() in source/arch/arm-m/process.zig.
  // Keep the two together: reinstating FPCCR.LSPEN requires fixing this return
  // to carry the entry FType.
  //
  // Still outstanding with lazy stacking off: this phase runs with FPCA=0, so a
  // PendSV landing here stores the software frame with is_fpu=0 and skips
  // s16-s31. A process holding live values there across a syscall loses them if
  // another process touches those registers first.
  ldr r3, =0xfffffffd
  pop {r4, r5, r6, r7}
  // process stack is modified, but not yet ready to be switched, block context switch till prepared
  bx r3 // we are taking back context from 134
process_syscall_unblock_context_switch:
  push {r0, lr}
  bl process_unblock_context_switch
  pop {r0, pc}
.thumb_func
return_from_syscall:
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
  isb
  bic r0, r0, #3
  msr control, r0
  isb
  dsb
  pop {r0, pc}

// caller saved registers are already saved by exception entry
.global irq_pendsv
.thumb_func
irq_pendsv:
  tst lr, #0x10
  ite eq
  moveq r0, #1
  movne r0, #0
  push {r0, lr}
  // bl print_process_loaded
  bl do_context_switch
  cmp r0, #3
  beq pendsv_ignore
  cmp r0, #1
  beq pendsv_store_and_switch
  cmp r0, #2
  beq pendsv_switch_to_next_task
  cmp r0, #0
  beq pendsv_exit
pendsv_exit:
  pop {r0, r1}
  b switch_to_main_task
pendsv_store_and_switch:
  pop {r0, r1}
  bl store_and_switch_to_next_task
  bl apply_resume_privilege
  bx r0
pendsv_switch_to_next_task:
  pop {r0, r1}
  bl switch_to_next_task
  bl apply_resume_privilege
  bx r0
pendsv_ignore:
  pop {r0, pc}

// Set CONTROL.nPRIV for the thread we are about to return to, based on the
// resumed process's privilege flag (the root/init process stays privileged; all
// user processes run unprivileged). Only nPRIV is touched here: this runs in
// handler mode where SPSEL is handled by the exception return. r0 (the EXC_RETURN
// value the caller bx-es to) is preserved across the call.
//
// Two variants sharing one tail:
//  - apply_current_privilege: the process's STATIC flag. Correct at syscall
//    return and first entry, where the thread is about to run user code.
//  - apply_resume_privilege: the LIVE CONTROL.nPRIV captured when the resumed
//    context was stored (update_stack_pointer). Required on the PendSV resume
//    paths: a process preempted inside the privileged thread-mode phase of a
//    syscall must come back privileged — restoring the static flag there made
//    the resumed syscall body fault on its first kernel/peripheral access
//    (MemManage DACCVIOL on the UART STATE register in sys_read's polling
//    loop), silently killing the process mid-zmodem-transfer.
.thumb_func
apply_current_privilege:
  push {r0, r1, r2, lr}
  bl process_current_is_privileged // r0 = 1 if privileged
  b apply_privilege_tail
.thumb_func
apply_resume_privilege:
  push {r0, r1, r2, lr}
  bl process_resume_is_privileged  // r0 = 1 if privileged
apply_privilege_tail:
  mrs r1, control
  bic r1, r1, #1                   // assume privileged: nPRIV = 0
  cmp r0, #0
  bne 1f
  orr r1, r1, #1                   // unprivileged: nPRIV = 1
1:
  msr control, r1
  isb
  pop {r0, r1, r2, pc}


.global switch_to_the_first_task
.thumb_func
switch_to_the_first_task:
  push {r0, lr} // this will be taken by return to user mode
  mov r1, lr
  bl switch_to_next_task
  // Switch to PSP (SPSEL=1) and set nPRIV for the first task from its privilege
  // flag (the root/init process is privileged). This runs in thread mode on MSP,
  // so the SPSEL flip must be the final stack-affecting operation: pop the saved
  // exec-return value before the single CONTROL write that flips both bits.
  push {r0}
  bl process_current_is_privileged // r0 = 1 if privileged
  mov r2, r0
  pop {r0}                          // r0 = exec-return value (still on MSP)
  mrs r1, control
  bic r1, r1, #1                    // nPRIV = 0
  orr r1, r1, #2                    // SPSEL = 1 (use PSP)
  cmp r2, #0
  bne 1f
  orr r1, r1, #1                    // unprivileged: nPRIV = 1
1:
  msr control, r1
  isb
  dsb
  bx r0


// r0 - pid
// r1 - sp
// r2 - lr
.global process_get_back_to_parent_vfork
.thumb_func
process_get_back_to_parent_vfork:
  mov sp, r1
  push {r0, r2}
  bl process_unblock_context_switch
  pop {r0, r2}
  cpsie i
  bx r2

// r0 - pointer to child sp value (to rescue registers)
// r1 - pointer to child got value
// r2 - pointer to child return
// r3 - is fpu used
.global process_vfork_child
.thumb_func
process_vfork_child:
  push {r4-r12, lr}
  cmp r3, #1
  mov r3, sp
  mov sp, r0
  pop {r4-r12, lr}
  bne vfork_child_no_fpu
  vpop {s0-s31}
vfork_child_no_fpu:
  mov sp, r3
  push {r1, r2} // r9 for child, other for alignment
  ldr r0, =process_vfork_back_here
  mov r1, r3
  bl arch_store_vfork_back_point
  ldr r1, [sp, #4]
  mov r0, #0
  push {r0, r1}
  bl process_unblock_context_switch
  pop {r0, r1}
  cpsie i
  bx r1

.thumb_func
process_vfork_back_here:
  pop {r4-r12, pc}
