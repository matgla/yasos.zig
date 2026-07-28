//
// qemu_mps2.zig
//
// HAL root module for the ARM MPS2-AN505 (Cortex-M33 / ARMv8-M) as modelled by
// QEMU's `mps2-an505` machine. Reuses the shared cortex-m core (SysTick / NVIC
// Irq / Registers) and armv8-m register definitions; everything hardware
// specific (UART, time, memory, flash) is a small bare-metal implementation.
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

pub const internal = struct {
    pub const Uart = @import("source/uart.zig").Uart;
    pub const Time = @import("source/time.zig").Time;
    pub const Cpu = @import("source/cpu.zig").Cpu;
    pub const HardwareAtomic = @import("source/atomic.zig").HardwareAtomic;
    pub const Irq = @import("cortex-m").Irq;
    pub const ExternalMemory = @import("source/external_memory.zig").ExternalMemory;
    pub const Memory = @import("source/memory.zig").Memory;
    pub const Flash = @import("source/flash.zig").Flash;
    pub const RamFlash = @import("source/ramflash.zig").RamFlash;
    pub const SharedMemoryDisplay = @import("source/display_shm.zig").SharedMemoryDisplay;
};

pub const uart = @import("hal_interface").uart;
pub const time = @import("hal_interface").time.Time(internal.Time).create();
pub const cpu = @import("hal_interface").cpu.Cpu(internal.Cpu).create();
pub const irq = @import("hal_interface").irq.Irq(internal.Irq).create();
pub const atomic = @import("hal_interface").atomic.AtomicInterface(internal.HardwareAtomic);
pub var external_memory = @import("hal_interface").external_memory.ExternalMemory(internal.ExternalMemory).create();
pub const memory = @import("hal_interface").memory.Memory(internal.Memory).create();
pub const flash = @import("hal_interface").flash;
pub const display = @import("hal_interface").display;

pub const hw_atomic = internal.HardwareAtomic;

// Exposed so the shared armv8-m register definitions can do `@import("hal").mmio`.
pub const mmio = @import("mmio.zig");

comptime {
    _ = @import("startup/crt.zig");
}
