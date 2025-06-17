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

const log = &@import("../../log/kernel_log.zig").kernel_log;

const arch = @import("assembly.zig");

export fn irq_hard_fault() void {
    log.print("PANIC: Hard Fault occured!\n", .{});
    while (true) {
        asm volatile (
            \\ wfi
        );
    }
}

pub export fn irq_svcall(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) void {
    var arg_to_call = arg;
    if (number == c.sys_vfork) {
        const c_result: *volatile c.syscall_result = @ptrCast(@alignCast(out));
        const ctx: handlers.VForkContext = .{
            .lr = arch.get_lr(),
            .result = &c_result.*.result,
        };
        arg_to_call = @ptrCast(&ctx);
    }
    write_result(out, syscall_lookup_table[number](arg_to_call));
}

export fn irq_pendsv() void {
    const lr: u32 = arch.get_lr();
    if (process_manager.instance.scheduler.schedule_next()) {
        store_and_switch_to_next_task(lr);
    }
}
