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

const std = @import("std");

comptime {
    _ = @import("drivers/tests.zig");
    _ = @import("fs/tests.zig");
    _ = @import("scheduler/tests.zig");

    _ = @import("benchmark.zig");
    _ = @import("mutex.zig");
    _ = @import("modules.zig");
    _ = @import("process_manager.zig");
    _ = @import("memory/tests.zig");
    _ = @import("errno.zig");
    _ = @import("spawn.zig");
    _ = @import("semaphore.zig");
    _ = @import("dump_hardware.zig");
    _ = @import("process.zig");
    _ = @import("process/tests.zig");
    _ = @import("time.zig");
    _ = @import("interrupts/kernel_semaphore.zig");
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
