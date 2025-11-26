//
// arch.zig
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

const std = @import("std");

const config = @import("config");
pub const process = @import("arm-m").process;
pub const irq_handlers = @import("arm-m").irq_handlers;
pub const panic = @import("arm-m").panic;
pub const HardwareProcess = @import("arm-m").HardwareProcess;
pub const get_lr = @import("arm-m").get_lr;
pub const exc_return = @import("arm-m").exc_return;
pub const disable_interrupts = @import("arm-m").disable_interrupts;
pub const enable_interrupts = @import("arm-m").enable_interrupts;
pub const sync = @import("arm-m").sync;

export fn irq_memmanage() void {
    @panic("Memory management fault occurred");
}

export fn irq_busfault() void {
    @panic("Bus fault occurred");
}

export fn irq_usagefault() void {
    @panic("Usage fault occurred");
}

export fn irq_securefault() void {
    @panic("Secure fault occurred");
}

export fn irq_debugmonitor() void {
    @panic("Debug monitor fault occurred");
}

export fn print_register(reg: usize) void {
    std.log.err("Register value: {x}\n", .{reg});
}
