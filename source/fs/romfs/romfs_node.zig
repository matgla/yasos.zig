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

const interface = @import("interface");
const fatfs = @import("zfat");

const kernel = @import("kernel");

const FileHeader = @import("file_header.zig").FileHeader;
const RomFsFile = @import("romfs_file.zig").RomFsFile;
const RomFsDirectory = @import("romfs_directory.zig").RomFsDirectory;

// pub const RomFsNode = struct {
//     pub fn create(allocator: std.mem.Allocator, header: FileHeader) !kernel.fs.Node {
//         var baseinit: kernel.fs.INodeBase = undefined;
//         var h = header;
//         if (h.filetype() == kernel.fs.FileType.Directory) {
//             const dir: kernel.fs.IDirectory = try RomFsDirectory.InstanceType.create(header).interface.new(allocator);
//             baseinit = kernel.fs.INodeBase.InstanceType.create_directory(dir);
//         } else {
//             const file: kernel.fs.IFile = try RomFsFile.InstanceType.create(allocator, header).interface.new(allocator);
//             baseinit = kernel.fs.INodeBase.InstanceType.create_file(file);
//         }
//         return kernel.init(.{
//             .base = baseinit,
//             ._allocator = allocator,
//             ._header = header,
//             ._name = h.name(allocator),
//         });
//     }
// };
