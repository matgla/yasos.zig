//
// rp2040.zig
//
// Copyright (C) 2024 Mateusz Stadnik <matgla@live.com>
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

pub const internal = struct {
    pub const Uart = @import("source/uart.zig").Uart;
    pub const Time = @import("source/time.zig").Time;
    pub const Cpu = @import("source/cpu.zig").Cpu;
    pub const Mmio = @import("source/mmio.zig").Mmio;
    pub const Irq = @import("cortex-m0plus").Irq;
};

pub const uart = @import("hal_interface").uart;
pub const time = @import("hal_interface").time.Time(internal.Time).create();
pub const cpu = @import("hal_interface").cpu.Cpu(internal.Cpu).create();
pub const irq = @import("hal_interface").irq.Irq(internal.Irq).create();

pub const mmio = struct {
    pub fn Mmio(comptime RegisterDescription: anytype) type {
        return internal.Mmio(RegisterDescription);
    }
};

comptime {
    _ = @import("bootloader_stage2/boot2_rom.zig");
    _ = @import("hal_common");
    _ = @import("startup/crt.zig");
}
