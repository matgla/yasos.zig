// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.


pub const cmsis = @This();

pub const __NVIC_PRIO_BITS: u32 = 4;

pub const IRQn_Type = c_int;
pub const SVCall_IRQn: IRQn_Type = -5;
pub const PendSV_IRQn: IRQn_Type = -2;
pub const SysTick_IRQn: IRQn_Type = -1;

pub const SCB_ICSR_PENDSVSET_Msk: u32 = 1 << 28;

pub const SysTick_CTRL_ENABLE_Msk: u32 = 1 << 0;
pub const SysTick_CTRL_TICKINT_Msk: u32 = 1 << 1;
pub const SysTick_CTRL_CLKSOURCE_Msk: u32 = 1 << 2;
pub const SysTick_LOAD_RELOAD_Msk: u32 = 0x00FFFFFF;

const SysTickRegs = extern struct {
    ctrl: u32,
    load: u32,
    val: u32,
    calib: u32,
};

const systick: *volatile SysTickRegs = @ptrFromInt(0xE000E010);
const shpr3_systick_prio: *volatile u8 = @ptrFromInt(0xE000ED23);

pub fn SysTick_Config(ticks: u32) u32 {
    if ((ticks -% 1) > SysTick_LOAD_RELOAD_Msk) return 1;
    systick.load = ticks -% 1;
    shpr3_systick_prio.* = @intCast(((@as(u32, 1) << __NVIC_PRIO_BITS) - 1) << (8 - __NVIC_PRIO_BITS));
    systick.val = 0;
    systick.ctrl = SysTick_CTRL_CLKSOURCE_Msk | SysTick_CTRL_TICKINT_Msk | SysTick_CTRL_ENABLE_Msk;
    return 0;
}
