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

#include <hardware/regs/resets.h>
#include <hardware/resets.h>
#include <pico/runtime_init.h>
#include <pico/time.h>
#include <hardware/vreg.h>
#include <hardware/clocks.h>
#include <hardware/pll.h>
#include <hardware/xosc.h>
#include <hardware/ticks.h>
#include <hardware/structs/qmi.h>
#include <hardware/regs/clocks.h>
#include <overclock.h>
