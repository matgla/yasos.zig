// Copyright (c) 2025 Mateusz Stadnik
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

pub const memory = @import("memory/memory.zig");
pub const log = @import("kernel_log.zig").log;
pub const kernel_stdout_log = @import("kernel_log.zig").kernel_stdout_log;
pub const stdout = @import("stdout.zig");
pub const file_log = @import("file_log.zig");

pub const process = struct {
    pub const process_manager = @import("process_manager.zig");
    pub const Process = @import("process.zig").Process;
    pub const VForkContext = @import("process.zig").VForkContext;
    pub const initialize_context_switching = @import("process.zig").initialize_context_switching;
    pub const get_offset_of_hardware_stored_registers = @import("arch").process.get_offset_of_hardware_stored_registers;
    pub const init = @import("process.zig").init;
    pub const ProcFs = @import("process/procfs.zig").ProcFs;
    pub const uart_stats = @import("process/uartstat_file.zig");
    pub const xip_stats = @import("process/xipstat_file.zig");
    pub const create_default_resource_limits = @import("process.zig").create_default_resource_limits;
};

pub const sync = struct {
    /// Userspace-facing counting semaphore -- a syscall wrapper, not a kernel
    /// primitive. `sync/` below is the kernel side.
    pub const Semaphore = @import("semaphore.zig").Semaphore;

    const primitives = @import("sync/sync.zig");
    pub const Atomic = primitives.Atomic;
    pub const SpinLock = primitives.SpinLock;
    pub const IrqState = primitives.IrqState;
    pub const Isolated = primitives.Isolated;
    pub const reservation_granule_bytes = primitives.reservation_granule_bytes;
    pub const placement = primitives.placement;
    pub const refcount = primitives.refcount;
    pub const Seq64 = primitives.Seq64;
    pub const locks = primitives.locks;
    pub const RankedMutex = primitives.RankedMutex;
    pub const Rank = primitives.Rank;
    pub const Ranked = primitives.Ranked;
    pub const RecursiveSpinLock = primitives.RecursiveSpinLock;
    pub const PerCpu = primitives.PerCpu;
    pub const percpu = primitives.percpu;
    pub const preempt = primitives.preempt;
    pub const init = primitives.init;
};

pub const spawn = @import("spawn.zig");

/// Secondary-core bring-up. Forced into the build rather than merely exposed:
/// `kernel_secondary_core_entry` is reached only from the board's core-N reset
/// assembly, so nothing in Zig references it and it would otherwise not be
/// emitted -- the same reason `source/arch/*/arch.zig` force their irq_handlers.
pub const smp = @import("smp.zig");
comptime {
    _ = @import("smp.zig");
}

pub const uaccess = @import("uaccess.zig");
pub const fs = @import("fs/fs.zig");
pub const dynamic_loader = @import("modules.zig");

pub const irq = @import("interrupts/interrupts.zig");

/// Syscall/IO profiling counters. Exposed here so filesystem code, which lives
/// outside the kernel directory, can attribute its own work; every entry point
/// compiles to nothing unless CONFIG_INSTRUMENTATION_PERF_PROFILING is on.
pub const perf = @import("interrupts/perf_profile.zig");

pub const driver = @import("drivers/drivers.zig");
pub const benchmark = @import("benchmark.zig");

pub const errno = @import("errno.zig");

pub const scheduler = @import("scheduler/scheduler.zig");

pub const DumpHardware = @import("dump_hardware.zig").DumpHardware;
