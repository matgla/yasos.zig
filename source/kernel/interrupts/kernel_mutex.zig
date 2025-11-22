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

const hal = @import("hal");

const kernel = @import("../kernel.zig");

pub const KernelMutex = struct {
    _lock: hal.atomic.Atomic(bool) = hal.atomic.Atomic(bool).create(false),
    _process: ?*kernel.process.Process = null,

    pub fn lock(self: *KernelMutex) void {
        if (self._process != null) {
            const current_process = kernel.process.process_manager.instance.get_current_process();
            if (self._process == current_process) {
                return;
            }
        }
        while (!self._lock.compare_exchange(false, true)) {
            hal.irq.trigger(.pendsv);
        }
        self._process = kernel.process.process_manager.instance.get_current_process();
    }

    pub fn unlock(self: *KernelMutex) void {
        self._lock.store(false);
        self._process = null;
    }
};
