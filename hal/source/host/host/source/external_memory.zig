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

const config = @import("config");

pub const ExternalMemory = struct {
    _initialized: bool = false,
    _psram_size: u32 = 0,

    pub fn enable(self: *ExternalMemory) bool {
        _ = self;
        return true;
    }

    pub fn disable(self: *ExternalMemory) void {
        _ = self;
    }

    pub fn dump_configuration(self: ExternalMemory, stdout: anytype) void {
        stdout.write("----- QMI Configuration ------\n");
        stdout.print(" enabled:    {any}\n", .{self._initialized});
        stdout.print(" psram size: {d} bytes\n", .{self._psram_size});
        stdout.print(" This is emulated memory on host machine!\n", .{});
        stdout.write("------------------------------\n");
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
