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

const c = @cImport({
    @cInclude("libs/libc/sys/syscall.h");
});

const log = std.log.scoped(.hardfault);
const CpuRegisters = @TypeOf(hal.cpu).Registers;

export fn irq_hard_fault() void {
    const exc_return = read_exception_return();
    const active_stack_address = read_fault_stack_pointer();
    const frame = FaultFrame.from_pointer(@ptrFromInt(active_stack_address));

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
    log.err("  PSP=0x{X:0>8} MSP=0x{X:0>8} PSPLIM=0x{X:0>8} MSPLIM=0x{X:0>8}", .{ psp, msp, psplim, msplim });
    log.err("  CFSR=0x{X:0>8} HFSR=0x{X:0>8} MMFAR=0x{X:0>8} BFAR=0x{X:0>8}", .{ cfsr_raw, hfsr_raw, mmfar, bfar });

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
