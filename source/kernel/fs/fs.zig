//
// fs.zig
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

pub const IFileSystem = @import("ifilesystem.zig").IFileSystem;
pub const IFile = @import("ifile.zig").IFile;
pub const VirtualFileSystem = @import("vfs.zig").VirtualFileSystem;
pub const vfs_init = @import("vfs.zig").vfs_init;
pub const vfs = @import("vfs.zig").vfs;
pub const ivfs = @import("vfs.zig").ivfs;
