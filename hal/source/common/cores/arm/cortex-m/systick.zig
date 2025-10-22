//
// systick.zig
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

const c = @import("cmsis").cmsis;

const cpu = @import("arch").Registers;

const std = @import("std");

pub const SysTick = struct {
    pub const SysTickError = error{
        ConfigurationFailure,
        ReloadValueImpossibleToReach,
    };

    fn configure_ticks(ticks: u32) !void {
        if ((ticks - 1) > c.SysTick_LOAD_RELOAD_Msk) {
            return SysTickError.ReloadValueImpossibleToReach;
        }
        cpu.systick.load.write(ticks - 1);
        cpu.nvic.set_priority(c.SysTick_IRQn, (1 << c.__NVIC_PRIO_BITS) - 1);
        cpu.systick.val.write(0);
        cpu.systick.ctrl.write(c.SysTick_CTRL_CLKSOURCE_Msk | c.SysTick_CTRL_TICKINT_Msk | c.SysTick_CTRL_ENABLE_Msk);
    }

    pub fn init(_: SysTick, ticks: u32) !void {
        try configure_ticks(ticks);
        // if (c.SysTick_Config(ticks) != 0) {
        //     return SysTickError.ConfigurationFailure;
        // }
    }

    pub fn disable(_: SysTick) void {
        const ctrl: usize = cpu.systick.ctrl.read();
        cpu.systick.ctrl.write(ctrl & ~(c.SysTick_CTRL_CLKSOURCE_Msk | c.SysTick_CTRL_ENABLE_Msk));
    }

    pub fn enable(_: SysTick) void {
        const ctrl: usize = cpu.systick.ctrl.read();
        cpu.systick.ctrl.write(ctrl | (c.SysTick_CTRL_CLKSOURCE_Msk | c.SysTick_CTRL_ENABLE_Msk));
    }
};
