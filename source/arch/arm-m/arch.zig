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

pub const process = @import("process.zig");
pub const irq_handlers = @import("irq_handlers.zig");
comptime {
    _ = @import("irq_handlers.zig");
}
pub const panic = @import("panic.zig");
pub const HardwareProcess = @import("process.zig").ArmProcess;
pub const get_lr = @import("assembly.zig").get_lr;
pub const exc_return = @import("exc_return.zig");
pub const disable_interrupts = @import("sync.zig").disable_interrupts;
pub const enable_interrupts = @import("sync.zig").enable_interrupts;
pub const memory_barrier_acquire = @import("sync.zig").memory_barrier_acquire;
pub const memory_barrier_release = @import("sync.zig").memory_barrier_release;
pub const sync = @import("sync.zig");
