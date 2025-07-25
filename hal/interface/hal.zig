//
// hal.zig
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

pub const uart = @import("uart.zig");
pub const time = @import("time.zig");
pub const cpu = @import("cpu.zig");
pub const mmio = @import("mmio.zig");
pub const irq = @import("irq.zig");
pub const atomic = @import("atomic.zig");
pub const external_memory = @import("external_memory.zig");
pub const memory = @import("memory.zig");
pub const mmc = @import("mmc.zig");
pub const flash = @import("flash.zig");
