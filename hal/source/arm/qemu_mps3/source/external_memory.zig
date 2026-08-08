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

// MPS2-AN505 (QEMU) has no external memory interface; the large process pool is
// just on-board SRAM reported by memory.zig. This is an inert stub — the kernel
// only touches it on the rp2350 path (guarded in source/main.zig).
pub const ExternalMemory = struct {
    _initialized: bool = false,
    _psram_size: u32 = 0,

    pub fn enable(self: *ExternalMemory) bool {
        _ = self;
        return false;
    }

    pub fn disable(self: *ExternalMemory) void {
        _ = self;
    }

    pub fn dump_configuration(self: ExternalMemory, stdout: anytype) void {
        _ = self;
        _ = stdout;
    }

    pub fn get_memory_size(self: ExternalMemory) usize {
        return self._psram_size;
    }

    pub fn perform_post(self: *ExternalMemory, stdout: anytype) bool {
        _ = self;
        _ = stdout;
        return true;
    }
};
