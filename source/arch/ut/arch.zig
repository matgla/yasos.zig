// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

pub const process = @import("hardware_process.zig");
pub const HardwareProcess = process.HardwareProcess;

export fn switch_to_main_task() void {}

var sp: usize = 0;
export fn arch_get_stack_pointer() *usize {
    return &sp;
}
pub const panic = @import("panic.zig");
pub const irq_handlers = @import("irq_handlers.zig");
pub const exc_return = struct {
    pub const return_to_handler_msp: u32 = 0xfffffff1;
    pub const return_to_thread_msp: u32 = 0xfffffff9;
    pub const return_to_thread_psp: u32 = 0xfffffffd;
    pub const return_to_handler_mode_with_fp_msp: u32 = 0xffffffe1;
    pub const return_to_thread_mode_with_fp_msp: u32 = 0xffffffe9;
    pub const return_to_thread_mode_with_fp_psp: u32 = 0xffffffed;
};

pub fn disable_interrupts() void {}
pub fn enable_interrupts() void {}

pub fn memory_barrier_release() void {}
pub fn memory_barrier_acquire() void {}

pub const sync = struct {
    pub inline fn save_and_disable_interrupts() usize {
        return 0;
    }

    pub inline fn restore_interrupts(primask: usize) void {
        _ = primask;
    }
};
