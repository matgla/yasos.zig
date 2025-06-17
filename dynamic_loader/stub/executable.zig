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

pub const Executable = struct {
    module: *Module,

    pub fn main(self: Executable, argv: [*c][*c]u8, argc: i32) error{MainNotExits}!i32 {
        _ = self;
        _ = argv;
        _ = argc;
    }

    pub fn deinit(self: *Executable) void {
        _ = self;
    }
};
