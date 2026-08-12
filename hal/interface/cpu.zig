//
// cpu.zig
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

/// A core-to-core interrupt handler. Reached from a vector table entry, so it
/// takes no arguments and returns nothing.
pub const DoorbellHandler = *const fn () callconv(.c) void;

pub fn Cpu(comptime cpu: anytype) type {
    const CpuImplementation = cpu;
    return struct {
        const Self = @This();
        pub const Registers = CpuImplementation.Registers;

        impl: CpuImplementation,

        pub fn create() Self {
            return Self{
                .impl = CpuImplementation{},
            };
        }

        pub fn name(_: Self) []const u8 {
            return CpuImplementation.name();
        }

        pub fn frequency(_: Self) u64 {
            return CpuImplementation.frequency();
        }

        pub fn number_of_cores(_: Self) u8 {
            return CpuImplementation.number_of_cores();
        }

        pub fn coreid(_: Self) u8 {
            return CpuImplementation.coreid();
        }

        pub fn set_stack_guard(_: Self, stack_guard: ?*const u8) void {
            CpuImplementation.set_stack_guard(stack_guard);
        }

        /// Release a secondary core so it starts executing the board's core-N
        /// reset path, which ends in the kernel's `kernel_secondary_core_entry`.
        /// Returns whether the request was issued; `false` means this board
        /// cannot start that core, and the kernel keeps running on the ones it
        /// has. Boards that do not declare it are single-core to the kernel.
        pub fn start_core(_: Self, core: u8) bool {
            if (@hasDecl(CpuImplementation, "start_core")) {
                return CpuImplementation.start_core(core);
            }
            return false;
        }

        /// Interrupt another core so it re-enters the scheduler now rather than
        /// on its next timer tick. Returns whether a doorbell was rung; `false`
        /// means this board has no core-to-core interrupt and the caller must be
        /// correct without one. The SSE-200 QEMU board takes that path.
        pub fn ring_doorbell(_: Self, core: u8) bool {
            if (@hasDecl(CpuImplementation, "ring_doorbell")) {
                return CpuImplementation.ring_doorbell(core);
            }
            return false;
        }

        /// Acknowledge any doorbell rung on the calling core. Must happen before
        /// the handler returns: the interrupt is level-held, so an unacknowledged
        /// bell re-fires immediately.
        pub fn clear_doorbell(_: Self) void {
            if (@hasDecl(CpuImplementation, "clear_doorbell")) {
                CpuImplementation.clear_doorbell();
            }
        }

        /// Let the calling core take doorbell interrupts. Per core -- the NVIC is
        /// banked, so each core enables its own.
        pub fn enable_doorbell(_: Self) void {
            if (@hasDecl(CpuImplementation, "enable_doorbell")) {
                CpuImplementation.enable_doorbell();
            }
        }

        /// Whether this board can interrupt another core at all. Reported through
        /// `/proc/cpus` so a wake-latency measurement says which path it measured.
        pub fn has_doorbell(_: Self) bool {
            return @hasDecl(CpuImplementation, "ring_doorbell");
        }

        /// Point the doorbell interrupt at the kernel's handler. Installed once
        /// rather than per core, since the vector table is shared; only the NVIC
        /// enable (`enable_doorbell`) is per core.
        pub fn install_doorbell_handler(_: Self, handler: DoorbellHandler) void {
            if (@hasDecl(CpuImplementation, "install_doorbell_handler")) {
                CpuImplementation.install_doorbell_handler(handler);
            }
        }

        pub fn vreg_vsel(_: Self) ?u8 {
            if (@hasDecl(CpuImplementation, "vreg_vsel")) {
                return CpuImplementation.vreg_vsel();
            }
            return null;
        }
    };
}
