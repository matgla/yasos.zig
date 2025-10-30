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

pub const AtomicStub = @import("atomic.zig").AtomicStub;
pub const IrqStub = @import("irq.zig").IrqStub;
pub const MemoryStub = @import("memory.zig").MemoryStub;
pub const TimeStub = @import("time.zig").TimeStub;
pub const CpuStub = @import("cpu.zig").CpuStub;

pub const atomic = @import("hal_interface").atomic.AtomicInterface(AtomicStub);
pub const irq = @import("hal_interface").irq.Irq(IrqStub).create();

pub const memory = @import("hal_interface").memory.Memory(MemoryStub).create();

pub const time = @import("hal_interface").time.Time(TimeStub).create();
pub const cpu = @import("hal_interface").cpu.Cpu(CpuStub).create();
