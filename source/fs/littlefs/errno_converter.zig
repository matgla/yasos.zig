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
const kernel = @import("kernel");
const littlefs = @import("littlefs_cimport.zig").littlefs;

pub fn lfs_error_to_errno(err: c_int) kernel.errno.ErrnoSet {
    return switch (err) {
        littlefs.LFS_ERR_IO, littlefs.LFS_ERR_CORRUPT => kernel.errno.ErrnoSet.InputOutputError,
        littlefs.LFS_ERR_NOENT => kernel.errno.ErrnoSet.NoEntry,
        littlefs.LFS_ERR_EXIST => kernel.errno.ErrnoSet.FileExists,
        littlefs.LFS_ERR_NOTDIR => kernel.errno.ErrnoSet.NotADirectory,
        littlefs.LFS_ERR_ISDIR => kernel.errno.ErrnoSet.IsADirectory,
        littlefs.LFS_ERR_NOTEMPTY => kernel.errno.ErrnoSet.DeviceOrResourceBusy,
        littlefs.LFS_ERR_BADF => kernel.errno.ErrnoSet.BadFileDescriptor,
        littlefs.LFS_ERR_FBIG => kernel.errno.ErrnoSet.FileTooLarge,
        littlefs.LFS_ERR_INVAL => kernel.errno.ErrnoSet.InvalidArgument,
        littlefs.LFS_ERR_NOSPC => kernel.errno.ErrnoSet.NoSpaceLeftOnDevice,
        littlefs.LFS_ERR_NOMEM => kernel.errno.ErrnoSet.OutOfMemory,
        littlefs.LFS_ERR_NOATTR => kernel.errno.ErrnoSet.NoEntry,
        littlefs.LFS_ERR_NAMETOOLONG => kernel.errno.ErrnoSet.InvalidArgument,
        0 => kernel.errno.ErrnoSet.Invalid,
        else => kernel.errno.ErrnoSet.InvalidArgument,
    };
}

test "LittleFs.ErrnoConverter" {
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InputOutputError, lfs_error_to_errno(littlefs.LFS_ERR_IO));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InputOutputError, lfs_error_to_errno(littlefs.LFS_ERR_CORRUPT));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NoEntry, lfs_error_to_errno(littlefs.LFS_ERR_NOENT));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.FileExists, lfs_error_to_errno(littlefs.LFS_ERR_EXIST));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NotADirectory, lfs_error_to_errno(littlefs.LFS_ERR_NOTDIR));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.IsADirectory, lfs_error_to_errno(littlefs.LFS_ERR_ISDIR));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.DeviceOrResourceBusy, lfs_error_to_errno(littlefs.LFS_ERR_NOTEMPTY));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.BadFileDescriptor, lfs_error_to_errno(littlefs.LFS_ERR_BADF));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.FileTooLarge, lfs_error_to_errno(littlefs.LFS_ERR_FBIG));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InvalidArgument, lfs_error_to_errno(littlefs.LFS_ERR_INVAL));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NoSpaceLeftOnDevice, lfs_error_to_errno(littlefs.LFS_ERR_NOSPC));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.OutOfMemory, lfs_error_to_errno(littlefs.LFS_ERR_NOMEM));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NoEntry, lfs_error_to_errno(littlefs.LFS_ERR_NOATTR));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InvalidArgument, lfs_error_to_errno(littlefs.LFS_ERR_NAMETOOLONG));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.Invalid, lfs_error_to_errno(0));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InvalidArgument, lfs_error_to_errno(-12345));
}
