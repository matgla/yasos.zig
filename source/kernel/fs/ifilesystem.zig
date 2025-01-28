//
// filesystem.zig
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

pub const IFileSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mount: *const fn (ctx: *anyopaque) void,
        has_path: *const fn (ctx: *anyopaque, path: []const u8) bool,
    };

    pub fn mount(self: IFileSystem) void {
        self.vtable.mount(self.ptr);
    }

    pub fn has_path(self: IFileSystem, path: []const u8) bool {
        return self.vtable.has_path(self.ptr, path);
    }
};
