//
// system_call.zig
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

const irq = @import("hal").irq;

extern fn switch_to_next_task() void;
extern fn store_and_switch_to_next_task() void;

export fn irq_svcall(number: u32) void {
    switch (@as(SystemCall, @enumFromInt(number))) {
        .start_root_process => switch_to_next_task(),
    }
}

export fn irq_pendsv() void {
    store_and_switch_to_next_task();
}

pub const SystemCall = enum(u32) {
    start_root_process = 1,
};

pub fn trigger(number: SystemCall) void {
    irq.trigger_supervisor_call(@intFromEnum(number));
}
