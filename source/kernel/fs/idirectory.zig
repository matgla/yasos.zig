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

const interface = @import("interface");
const IFile = @import("ifile.zig").IFile;

pub const IDirectoryIterator = interface.ConstructInterface(struct {
    pub const Self = @This();

    pub fn next(self: *Self) ?IFile {
        return interface.VirtualCall(self, "next", .{}, ?IFile);
    }

    pub fn delete(self: *Self) void {
        interface.DestructorCall(self);
    }
});
