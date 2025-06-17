//
// irq_handlers.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
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
//

// const log = &@import("../../log/kernel_log.zig").kernel_log;
// const log = @import("kernel_log");

const std = @import("std");
const hal = @import("hal");
const arch = @import("assembly.zig");
const arch_process = @import("process.zig");
const c = @import("libc_imports").c;

const log = std.log.scoped(.hardfault);
const CpuRegisters = @TypeOf(hal.cpu).Registers;
const HardwareStoredRegisters = arch_process.HardwareStoredRegisters;

extern fn get_stack_top() *const u8;
extern fn get_current_pid() c.pid_t;
extern fn file_log_disable() void;
extern fn _exit(code: c_int) void;

const usage_fault_stkof_mask: u32 = 1 << 20;
const stack_overflow_exit_code: c_int = -1;

// FPU context/lazy-stacking control registers (ARMv8-M, dump only).
const fpccr: *volatile u32 = @ptrFromInt(0xE000EF34);
const fpcar: *volatile u32 = @ptrFromInt(0xE000EF38);

// On-chip SRAM occupied by the kernel: handler/main stack + kernel data. A user
// process running on PSP (PSRAM) must never hold one of these as a live
// register value; if it does after a fault, a context switch leaked a kernel
// register into the process context. RP2350 SRAM is 0x20000000..0x20082000.
const kernel_sram_begin: usize = 0x20000000;
const kernel_sram_end: usize = 0x20082000;

fn in_kernel_sram(addr: usize) bool {
    return addr >= kernel_sram_begin and addr < kernel_sram_end;
}

// User code executes from the romfs/app region in flash (>= 0x10100000) or from
// PSRAM (0x11xxxxxx); kernel code lives below 0x10100000. The leak heuristic
// only makes sense for a user fault — kernel code legitimately holds kernel-SRAM
// pointers (frame pointers, stack addresses) in r4-r11.
const romfs_begin: usize = 0x10100000;
fn is_user_text(pc: usize) bool {
    return pc >= romfs_begin and pc < 0x12000000;
}

// Readable RAM windows we are willing to peek at from the fault handler.
fn is_readable_ram(addr: usize) bool {
    return (addr >= 0x11000000 and addr < 0x11800000) or // PSRAM
        (addr >= kernel_sram_begin and addr < kernel_sram_end); // SRAM
}

// Dump up to `count` words starting at `start` (word-aligned), 4 per line,
// skipping any word whose address is not in mapped RAM so a bogus SP can't
// fault us a second time.
fn dump_memory_window(label: []const u8, start: usize, count: usize) void {
    const base = start & ~@as(usize, 0x3);
    if (!is_readable_ram(base)) {
        log.err("  {s} @0x{X:0>8}: <unmapped, skipped>", .{ label, base });
        return;
    }
    log.err("  {s} @0x{X:0>8}:", .{ label, base });
    var i: usize = 0;
    while (i < count) : (i += 4) {
        const a0 = base + i * 4;
        if (!is_readable_ram(a0)) break;
        const p0: *const volatile u32 = @ptrFromInt(a0);
        const p1: *const volatile u32 = @ptrFromInt(a0 + 4);
        const p2: *const volatile u32 = @ptrFromInt(a0 + 8);
        const p3: *const volatile u32 = @ptrFromInt(a0 + 12);
        log.err("    0x{X:0>8}: {X:0>8} {X:0>8} {X:0>8} {X:0>8}", .{ a0, p0.*, p1.*, p2.*, p3.* });
    }
}

export fn irq_hard_fault() void {
    // Capture callee-saved regs (r4-r11) BEFORE any handler code can clobber
    // them. On exception entry these are NOT auto-stacked, so they still hold
    // the faulting context's values. Needed to diagnose frame-pointer (r7/r11)
    // corruption that manifests as a bogus `mov sp, rN` STKOF.
    var callee: [8]usize = undefined;
    asm volatile (
        \\ stmia %[p], {r4-r11}
        :
        : [p] "{r0}" (&callee),
        : .{ .memory = true }
    );
    // SDIO depends on lower-priority interrupts that are masked inside the
    // fault handler, so a blocking SD write here would hang. Route the
    // postmortem to the console only; everything before the fault is already
    // persisted line-by-line on the card.
    file_log_disable();

    const exc_return = read_exception_return();
    const active_stack_address = read_fault_stack_pointer();
    const frame_ptr: *volatile FaultFrame = @ptrFromInt(active_stack_address);
    const frame = frame_ptr.*;

    const scb = CpuRegisters.scb;
    const cfsr_raw: u32 = @as(u32, @bitCast(scb.cfsr.read()));
    const hfsr_raw: u32 = scb.hfsr.read();
    const mmfar = scb.mmfar.read();
    const bfar = scb.bfar.read();

    const psp = read_psp();
    const msp = read_msp();
    const psplim = read_psplim();
    const msplim = read_msplim();

    log.err("HardFault diagnostics:", .{});
    log.err("  EXC_RETURN=0x{X:0>8} stacked_pc=0x{X:0>8} stacked_lr=0x{X:0>8}", .{ exc_return, frame.pc, frame.lr });
    log.err(
        "  stacked r0=0x{X:0>8} r1=0x{X:0>8} r2=0x{X:0>8} r3=0x{X:0>8} r12=0x{X:0>8} psr=0x{X:0>8}",
        .{ frame.r0, frame.r1, frame.r2, frame.r3, frame.r12, frame.psr },
    );
    log.err(
        "  r4=0x{X:0>8} r5=0x{X:0>8} r6=0x{X:0>8} r7=0x{X:0>8} r8=0x{X:0>8} r9=0x{X:0>8} r10=0x{X:0>8} r11=0x{X:0>8}",
        .{ callee[0], callee[1], callee[2], callee[3], callee[4], callee[5], callee[6], callee[7] },
    );
    log.err("  PSP=0x{X:0>8} MSP=0x{X:0>8} PSPLIM=0x{X:0>8} MSPLIM=0x{X:0>8}", .{ psp, msp, psplim, msplim });
    log.err("  CFSR=0x{X:0>8} HFSR=0x{X:0>8} MMFAR=0x{X:0>8} BFAR=0x{X:0>8}", .{ cfsr_raw, hfsr_raw, mmfar, bfar });
    log.err("  pid={d} FPCCR=0x{X:0>8} FPCAR=0x{X:0>8} (LSPACT={d})", .{ get_current_pid(), fpccr.*, fpcar.*, (fpccr.* >> 0) & 1 });

    // Corruption heuristic: a user-process (PSP) fault should never carry a live
    // register that points into kernel SRAM. If one does, a context switch most
    // likely restored a stale kernel-side register into the process context.
    // This is the signature of the recurring r7=0x2008xxxx leak.
    if (uses_process_stack(exc_return) and is_user_text(frame.pc)) {
        const named = [_]struct { n: []const u8, v: usize }{
            .{ .n = "pc", .v = frame.pc },  .{ .n = "lr", .v = frame.lr },
            .{ .n = "r4", .v = callee[0] }, .{ .n = "r5", .v = callee[1] },
            .{ .n = "r6", .v = callee[2] }, .{ .n = "r7", .v = callee[3] },
            .{ .n = "r8", .v = callee[4] }, .{ .n = "r9", .v = callee[5] },
            .{ .n = "r10", .v = callee[6] }, .{ .n = "r11", .v = callee[7] },
        };
        for (named) |reg| {
            if (in_kernel_sram(reg.v)) {
                log.err("  SUSPECT: {s}=0x{X:0>8} points into kernel SRAM (context-switch register leak?)", .{ reg.n, reg.v });
            }
        }
    }

    // Postmortem stack windows: the faulting frame (reveals what called the
    // faulting code) and the live process stack near PSP (reveals poison fills
    // like 0xAAAAAAAA and the saved-context layout).
    dump_memory_window("fault-frame", active_stack_address, 16);
    if (uses_process_stack(exc_return)) {
        dump_memory_window("psp", psp, 24);
    }

    if (is_psplim_overflow(exc_return, cfsr_raw)) {
        log.err("Process stack overflow detected, terminating current process", .{});
        scb.cfsr.write_raw(cfsr_raw);
        scb.hfsr.write_raw(hfsr_raw);
        write_psp(prepare_stack_overflow_exit_frame());
        return;
    }

    @panic("Hard fault occured");
    // while (true) {
    //     asm volatile (
    //         \\ wfi
    //     );
    // }
}
pub const VForkContext = extern struct {
    lr: usize,
    result: *volatile c.pid_t,
};

const ContextSwitchHandler = *const fn (lr: usize) usize;
const SystemCallHandler = *const fn (number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) callconv(.c) void;

var context_switch_handler: ContextSwitchHandler = undefined;
var system_call_handler: SystemCallHandler = undefined;

// export fn _irq_svcall(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) linksection(".time_critical") void {
//     // system_call_handler(number, arg, out);
//     _ = number;
//     _ = arg;
//     _ = out;
// }

// pub export fn do_context_switch(is_fpu_used: usize) usize {
//     return context_switch_handler(is_fpu_used);
// }

pub fn set_context_switch_handler(handler: ContextSwitchHandler) void {
    context_switch_handler = handler;
}

pub fn set_system_call_handler(handler: SystemCallHandler) void {
    system_call_handler = handler;
}

const FaultFrame = struct {
    r0: usize,
    r1: usize,
    r2: usize,
    r3: usize,
    r12: usize,
    lr: usize,
    pc: usize,
    psr: usize,

    pub fn from_pointer(ptr: [*]const usize) FaultFrame {
        return .{
            .r0 = ptr[0],
            .r1 = ptr[1],
            .r2 = ptr[2],
            .r3 = ptr[3],
            .r12 = ptr[4],
            .lr = ptr[5],
            .pc = ptr[6],
            .psr = ptr[7],
        };
    }
};

inline fn read_fault_stack_pointer() usize {
    return asm volatile (
        \\ tst lr, #4
        \\ ite eq
        \\ mrseq %[sp], msp
        \\ mrsne %[sp], psp
        : [sp] "=r" (-> usize),
    );
}

inline fn read_exception_return() usize {
    return asm volatile (
        \\ mov %[lr_out], lr
        : [lr_out] "=r" (-> usize),
    );
}

inline fn read_psp() usize {
    return asm volatile (
        \\ mrs %[out], psp
        : [out] "=r" (-> usize),
    );
}

inline fn read_msp() usize {
    return asm volatile (
        \\ mrs %[out], msp
        : [out] "=r" (-> usize),
    );
}

inline fn read_psplim() usize {
    return asm volatile (
        \\ mrs %[out], psplim
        : [out] "=r" (-> usize),
    );
}

inline fn read_msplim() usize {
    return asm volatile (
        \\ mrs %[out], msplim
        : [out] "=r" (-> usize),
    );
}

inline fn write_psp(value: usize) void {
    asm volatile (
        \\ msr psp, %[value]
        \\ isb
        \\ dsb
        :
        : [value] "r" (value),
    );
}

fn is_psplim_overflow(exc_return: usize, cfsr_raw: u32) bool {
    return uses_process_stack(exc_return) and (cfsr_raw & usage_fault_stkof_mask) != 0;
}

fn uses_process_stack(exc_return: usize) bool {
    return (exc_return & 0x4) != 0;
}

fn prepare_stack_overflow_exit_frame() usize {
    const stack_top = @intFromPtr(get_stack_top());
    const stack_frame_address = (stack_top - @sizeOf(HardwareStoredRegisters)) & ~@as(usize, 0x7);
    const recovery_frame: *volatile HardwareStoredRegisters = @ptrFromInt(stack_frame_address);

    recovery_frame.* = std.mem.zeroInit(HardwareStoredRegisters, .{});
    recovery_frame.r0 = @bitCast(@as(i32, stack_overflow_exit_code));
    recovery_frame.lr = 0;
    recovery_frame.pc = @intCast(@intFromPtr(&_exit));
    recovery_frame.psr = 0x21000000;

    return stack_frame_address;
}
