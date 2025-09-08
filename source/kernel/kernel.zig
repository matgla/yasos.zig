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

pub const process = struct {
    pub const process_manager = @import("process_manager.zig");
    pub const Process = @import("process.zig").Process;
    pub const initialize_context_switching = @import("process.zig").initialize_context_switching;
    pub const init = @import("process.zig").init;
    pub const ProcFs = @import("process/procfs.zig").ProcFs;
};

pub const spawn = @import("spawn.zig");
pub const fs = @import("fs/fs.zig");
pub const dynamic_loader = @import("modules.zig");

pub const irq = @import("interrupts/interrupts.zig");

pub const driver = @import("drivers/drivers.zig");
pub const benchmark = @import("benchmark.zig");
