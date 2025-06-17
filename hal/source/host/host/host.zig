//
// host.zig
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
    pub const Uart = @import("uart.zig").Uart;
    pub const Cpu = @import("source/cpu.zig").Cpu;
    pub const Memory = @import("source/memory.zig").Memory;
    pub const ExternalMemory = @import("source/external_memory.zig").ExternalMemory;
    pub const Irq = @import("source/irq.zig").Irq;
    pub const HardwareAtomic = @import("source/atomic.zig").HardwareAtomic;
    pub const Time = @import("source/time.zig").Time;
    pub const Mmc = @import("source/mmc.zig").Mmc;
};

pub const uart = @import("hal_interface").uart;
pub const cpu = @import("hal_interface").cpu.Cpu(internal.Cpu).create();
pub const memory = @import("hal_interface").memory.Memory(internal.Memory).create();
pub const irq = @import("hal_interface").irq.Irq(internal.Irq).create();
pub var external_memory = @import("hal_interface").external_memory.ExternalMemory(internal.ExternalMemory).create();
pub const atomic = @import("hal_interface").atomic.AtomicInterface(internal.HardwareAtomic);
pub const time = @import("hal_interface").time.Time(internal.Time).create();
pub const mmc = @import("hal_interface").mmc;
