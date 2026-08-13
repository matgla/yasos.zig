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

const ArchRegisters = @import("arch").Registers;

/// SSE-200 CPU_IDENTITY block, offset 0 = CPUID. Each core has its own copy of
/// this window mapped at the same address, so the read returns the reading
/// core's index -- the Cortex-M answer to "which core am I", since there is no
/// per-core general purpose register to cache it in.
///
/// A `*volatile u32` derived from the address rather than a volatile struct
/// field: this Zig mishandles direct volatile field access.
const cpu_identity_cpuid: *volatile u32 = @ptrFromInt(0x4001f000);

/// SSE-200 system control block, secure alias. Secure-only: unlike the board
/// peripherals there is no 0x4xxx_xxxx alias, and the kernel runs Secure.
const sse_sysctrl: usize = 0x5002_1000;

/// Secure vector table address core 1 resets to. The register's VTOR field
/// starts at bit 7, hence the 128-byte alignment on `__vector_table_core1`.
const initsvtor1: *volatile u32 = @ptrFromInt(sse_sysctrl + 0x114);

/// One bit per core: 1 holds that core at reset. Reset value is 2 on the
/// SSE-200, i.e. core 0 boots and core 1 waits. Clearing a bit is what starts
/// the core -- QEMU turns the 1->0 edge into `arm_set_cpu_on_and_reset()`.
const cpuwait: *volatile u32 = @ptrFromInt(sse_sysctrl + 0x118);

/// Core 1's reset vector table (startup.S): initial MSP and `_start_core1`.
extern var __vector_table_core1: u8;

pub const Cpu = struct {
    pub const Registers = ArchRegisters;

    pub fn name() []const u8 {
        return "Cortex-M33 (MPS3-AN524, SSE-200)";
    }

    // QEMU MPS3-AN524 SYSCLK is 25 MHz. Used for the 1 ms SysTick reload and
    // the hardware splash; not performance critical under emulation.
    pub fn frequency() u64 {
        return 25_000_000;
    }

    pub fn number_of_cores() u8 {
        return 2;
    }

    pub fn coreid() u8 {
        return @intCast(cpu_identity_cpuid.* & 0xff);
    }

    /// Release a core held by CPUWAIT. The core resets into
    /// `__vector_table_core1`, taking its MSP from word 0 and its entry from
    /// word 1, so there is nothing to pass here. Only core 1 exists to be
    /// started; anything else is refused rather than poking a reserved bit.
    pub fn start_core(core: u8) bool {
        if (core != 1) return false;
        initsvtor1.* = @intFromPtr(&__vector_table_core1);
        cpuwait.* = cpuwait.* & ~(@as(u32, 1) << @intCast(core));
        return true;
    }

    pub fn set_stack_guard(_: ?*const u8) void {}
};
