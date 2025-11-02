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

const fatfs = @import("zfat");
const kernel = @import("kernel");

pub fn fatfs_error_to_errno(err: fatfs.GlobalError) kernel.errno.ErrnoSet {
    switch (err) {
        fatfs.GlobalError.DiskErr => return kernel.errno.ErrnoSet.InputOutputError,
        fatfs.GlobalError.IntErr => return kernel.errno.ErrnoSet.InputOutputError,
        fatfs.GlobalError.NotReady => return kernel.errno.ErrnoSet.InputOutputError,
        fatfs.GlobalError.NoFile => return kernel.errno.ErrnoSet.NoEntry,
        fatfs.GlobalError.NoPath => return kernel.errno.ErrnoSet.NoEntry,
        fatfs.GlobalError.InvalidName => return kernel.errno.ErrnoSet.InvalidArgument,
        fatfs.GlobalError.Denied => return kernel.errno.ErrnoSet.PermissionDenied,
        fatfs.GlobalError.Exist => return kernel.errno.ErrnoSet.FileExists,
        fatfs.GlobalError.InvalidObject => return kernel.errno.ErrnoSet.InvalidArgument,
        fatfs.GlobalError.WriteProtected => return kernel.errno.ErrnoSet.ReadOnlyFileSystem,
        fatfs.GlobalError.InvalidDrive => return kernel.errno.ErrnoSet.NoEntry,
        fatfs.GlobalError.NotEnabled => return kernel.errno.ErrnoSet.PermissionDenied,
        fatfs.GlobalError.NoFilesystem => return kernel.errno.ErrnoSet.NoEntry,
        fatfs.GlobalError.MkfsAborted => return kernel.errno.ErrnoSet.InputOutputError,
        fatfs.GlobalError.Timeout => return kernel.errno.ErrnoSet.InputOutputError,
        fatfs.GlobalError.Locked => return kernel.errno.ErrnoSet.TextFileBusy,
        fatfs.GlobalError.OutOfMemory => return kernel.errno.ErrnoSet.OutOfMemory,
        fatfs.GlobalError.TooManyOpenFiles => return kernel.errno.ErrnoSet.TooManyOpenFiles,
        fatfs.GlobalError.InvalidParameter => return kernel.errno.ErrnoSet.InvalidArgument,
    }
}

test "FatFs.ErrnoConverter" {
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InputOutputError, fatfs_error_to_errno(fatfs.GlobalError.DiskErr));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InputOutputError, fatfs_error_to_errno(fatfs.GlobalError.IntErr));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InputOutputError, fatfs_error_to_errno(fatfs.GlobalError.NotReady));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NoEntry, fatfs_error_to_errno(fatfs.GlobalError.NoFile));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NoEntry, fatfs_error_to_errno(fatfs.GlobalError.NoPath));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InvalidArgument, fatfs_error_to_errno(fatfs.GlobalError.InvalidName));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.PermissionDenied, fatfs_error_to_errno(fatfs.GlobalError.Denied));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.FileExists, fatfs_error_to_errno(fatfs.GlobalError.Exist));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InvalidArgument, fatfs_error_to_errno(fatfs.GlobalError.InvalidObject));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.ReadOnlyFileSystem, fatfs_error_to_errno(fatfs.GlobalError.WriteProtected));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NoEntry, fatfs_error_to_errno(fatfs.GlobalError.InvalidDrive));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.PermissionDenied, fatfs_error_to_errno(fatfs.GlobalError.NotEnabled));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NoEntry, fatfs_error_to_errno(fatfs.GlobalError.NoFilesystem));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InputOutputError, fatfs_error_to_errno(fatfs.GlobalError.MkfsAborted));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InputOutputError, fatfs_error_to_errno(fatfs.GlobalError.Timeout));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.TextFileBusy, fatfs_error_to_errno(fatfs.GlobalError.Locked));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.OutOfMemory, fatfs_error_to_errno(fatfs.GlobalError.OutOfMemory));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.TooManyOpenFiles, fatfs_error_to_errno(fatfs.GlobalError.TooManyOpenFiles));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.InvalidArgument, fatfs_error_to_errno(fatfs.GlobalError.InvalidParameter));
}
