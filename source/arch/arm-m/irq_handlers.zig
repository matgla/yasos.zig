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

const arch = @import("assembly.zig");

const c = @cImport({
    @cInclude("source/sys/include/syscall.h");
});

export fn irq_hard_fault() void {
    // log.print("PANIC: Hard Fault occured!\n", .{});
    while (true) {
        asm volatile (
            \\ wfi
        );
    }
}
pub const VForkContext = extern struct {
    lr: usize,
    result: *volatile c.pid_t,
};

const ContextSwitchHandler = *const fn (lr: usize) void;
const SystemCallHandler = *const fn (number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) void;

var context_switch_handler: ?ContextSwitchHandler = null;
var system_call_handler: ?SystemCallHandler = null;

export var sp_call: usize = 0;
export fn irq_svcall() callconv(.Naked) void {
    asm volatile (
        \\ push {r0, r1}
        \\ ldr r0, =sp_call
        \\ mov r1, sp
        \\ adds r1, 8
        \\ str r1, [r0] 
        \\ pop {r0, r1}
        \\ push {r0, lr}
        \\ bl _irq_svcall 
        \\ pop {r0, pc} 
    );
}

export fn _irq_svcall(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) void {
    if (system_call_handler) |handler| {
        if (number == 1) {
            handler(number, &sp_call, out);
        } else {
            handler(number, arg, out);
        }
    }
}

export fn irq_pendsv() void {
    const lr: usize = arch.get_lr();
    if (context_switch_handler) |handler| {
        handler(lr);
    }
}

pub fn set_context_switch_handler(handler: ContextSwitchHandler) void {
    context_switch_handler = handler;
}

pub fn set_system_call_handler(handler: SystemCallHandler) void {
    system_call_handler = handler;
}
