//
// executable.zig
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

const Module = @import("module.zig").Module;

const get_loader = @import("loader.zig").get_loader;

extern fn call_main(argc: i32, argv: [*c][*c]u8, address: usize, got: usize) i32;
extern fn call_entry(address: usize, got: usize) i32;

pub const Executable = struct {
    module: *Module,

    pub fn main(self: Executable, argv: [*c][*c]u8, argc: i32) error{MainNotExits}!i32 {
        if (self.module.entry) |entry| {
            return call_main(argc, argv, entry.address, entry.target_got_address);
        }

        const maybe_symbol = self.module.find_symbol("_start");
        if (maybe_symbol) |symbol| {
            return call_main(argc, argv, symbol.address, symbol.target_got_address);
        }
        return error.MainNotExits;
    }

    pub fn deinit(self: *Executable) void {
        self.module.destroy();
    }
};
