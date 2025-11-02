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

const c = @import("libc_imports").c;

pub const ErrnoSet = error{
    NotPermitted,
    NoEntry,
    NoSuchProcess,
    InterruptedSystemCall,
    InputOutputError,
    NoSuchDeviceOrAddress,
    ArgumentListTooLong,
    ExecFormatError,
    BadFileDescriptor,
    NoChildProcesses,
    TryAgain,
    OutOfMemory,
    PermissionDenied,
    BadAddress,
    BlockDeviceRequired,
    DeviceOrResourceBusy,
    FileExists,
    CrossDeviceLink,
    NoSuchDevice,
    NotADirectory,
    IsADirectory,
    InvalidArgument,
    FileTableOverflow,
    TooManyOpenFiles,
    NotTypeWriter,
    TextFileBusy,
    FileTooLarge,
    NoSpaceLeftOnDevice,
    IllegalSeek,
    ReadOnlyFileSystem,
    TooManyLinks,
    BrokenPipe,
    MathArgumentOutOfDomain,
    MathResultNotRepresentable,
    TooManySymbolicLinks,
    Invalid,
    NotImplemented,
};

pub fn from_errno(rc: u16) anyerror {
    return switch (rc) {
        c.EPERM => ErrnoSet.NotPermitted,
        c.ENOENT => ErrnoSet.NoEntry,
        c.ESRCH => ErrnoSet.NoSuchProcess,
        c.EINTR => ErrnoSet.InterruptedSystemCall,
        c.EIO => ErrnoSet.InputOutputError,
        c.ENXIO => ErrnoSet.NoSuchDeviceOrAddress,
        c.E2BIG => ErrnoSet.ArgumentListTooLong,
        c.ENOEXEC => ErrnoSet.ExecFormatError,
        c.EBADF => ErrnoSet.BadFileDescriptor,
        c.ECHILD => ErrnoSet.NoChildProcesses,
        c.EAGAIN => ErrnoSet.TryAgain,
        c.ENOMEM => ErrnoSet.OutOfMemory,
        c.EACCES => ErrnoSet.PermissionDenied,
        c.EFAULT => ErrnoSet.BadAddress,
        c.ENOTBLK => ErrnoSet.BlockDeviceRequired,
        c.EBUSY => ErrnoSet.DeviceOrResourceBusy,
        c.EEXIST => ErrnoSet.FileExists,
        c.EXDEV => ErrnoSet.CrossDeviceLink,
        c.ENODEV => ErrnoSet.NoSuchDevice,
        c.ENOTDIR => ErrnoSet.NotADirectory,
        c.EISDIR => ErrnoSet.IsADirectory,
        c.EINVAL => ErrnoSet.InvalidArgument,
        c.ENFILE => ErrnoSet.FileTableOverflow,
        c.EMFILE => ErrnoSet.TooManyOpenFiles,
        c.ENOTTY => ErrnoSet.NotTypeWriter,
        c.ETXTBSY => ErrnoSet.TextFileBusy,
        c.EFBIG => ErrnoSet.FileTooLarge,
        c.ENOSPC => ErrnoSet.NoSpaceLeftOnDevice,
        c.ESPIPE => ErrnoSet.IllegalSeek,
        c.EROFS => ErrnoSet.ReadOnlyFileSystem,
        c.EMLINK => ErrnoSet.TooManyLinks,
        c.EPIPE => ErrnoSet.BrokenPipe,
        c.EDOM => ErrnoSet.MathArgumentOutOfDomain,
        c.ERANGE => ErrnoSet.MathResultNotRepresentable,
        c.ELOOP => ErrnoSet.TooManySymbolicLinks,
        c.ENOSYS => ErrnoSet.NotImplemented,
        else => ErrnoSet.Invalid,
    };
}

pub fn to_errno(err: anyerror) u16 {
    return switch (err) {
        ErrnoSet.NotPermitted => c.EPERM,
        ErrnoSet.NoEntry => c.ENOENT,
        ErrnoSet.NoSuchProcess => c.ESRCH,
        ErrnoSet.InterruptedSystemCall => c.EINTR,
        ErrnoSet.InputOutputError => c.EIO,
        ErrnoSet.NoSuchDeviceOrAddress => c.ENXIO,
        ErrnoSet.ArgumentListTooLong => c.E2BIG,
        ErrnoSet.ExecFormatError => c.ENOEXEC,
        ErrnoSet.BadFileDescriptor => c.EBADF,
        ErrnoSet.NoChildProcesses => c.ECHILD,
        ErrnoSet.TryAgain => c.EAGAIN,
        ErrnoSet.OutOfMemory => c.ENOMEM,
        ErrnoSet.PermissionDenied => c.EACCES,
        ErrnoSet.BadAddress => c.EFAULT,
        ErrnoSet.BlockDeviceRequired => c.ENOTBLK,
        ErrnoSet.DeviceOrResourceBusy => c.EBUSY,
        ErrnoSet.FileExists => c.EEXIST,
        ErrnoSet.CrossDeviceLink => c.EXDEV,
        ErrnoSet.NoSuchDevice => c.ENODEV,
        ErrnoSet.NotADirectory => c.ENOTDIR,
        ErrnoSet.IsADirectory => c.EISDIR,
        ErrnoSet.InvalidArgument => c.EINVAL,
        ErrnoSet.FileTableOverflow => c.ENFILE,
        ErrnoSet.TooManyOpenFiles => c.EMFILE,
        ErrnoSet.NotTypeWriter => c.ENOTTY,
        ErrnoSet.TextFileBusy => c.ETXTBSY,
        ErrnoSet.FileTooLarge => c.EFBIG,
        ErrnoSet.NoSpaceLeftOnDevice => c.ENOSPC,
        ErrnoSet.IllegalSeek => c.ESPIPE,
        ErrnoSet.ReadOnlyFileSystem => c.EROFS,
        ErrnoSet.TooManyLinks => c.EMLINK,
        ErrnoSet.BrokenPipe => c.EPIPE,
        ErrnoSet.MathArgumentOutOfDomain => c.EDOM,
        ErrnoSet.MathResultNotRepresentable => c.ERANGE,
        ErrnoSet.TooManySymbolicLinks => c.ELOOP,
        ErrnoSet.NotImplemented => c.ENOSYS,
        else => c.EINVAL,
    };
}

const std = @import("std");

test "Errno.ShouldConvertFromErrnoToErrorSet" {
    try std.testing.expectEqual(ErrnoSet.NotPermitted, from_errno(c.EPERM));
    try std.testing.expectEqual(ErrnoSet.NoEntry, from_errno(c.ENOENT));
    try std.testing.expectEqual(ErrnoSet.NoSuchProcess, from_errno(c.ESRCH));
    try std.testing.expectEqual(ErrnoSet.InterruptedSystemCall, from_errno(c.EINTR));
    try std.testing.expectEqual(ErrnoSet.InputOutputError, from_errno(c.EIO));
    try std.testing.expectEqual(ErrnoSet.NoSuchDeviceOrAddress, from_errno(c.ENXIO));
    try std.testing.expectEqual(ErrnoSet.ArgumentListTooLong, from_errno(c.E2BIG));
    try std.testing.expectEqual(ErrnoSet.ExecFormatError, from_errno(c.ENOEXEC));
    try std.testing.expectEqual(ErrnoSet.BadFileDescriptor, from_errno(c.EBADF));
    try std.testing.expectEqual(ErrnoSet.NoChildProcesses, from_errno(c.ECHILD));
    try std.testing.expectEqual(ErrnoSet.TryAgain, from_errno(c.EAGAIN));
    try std.testing.expectEqual(ErrnoSet.OutOfMemory, from_errno(c.ENOMEM));
    try std.testing.expectEqual(ErrnoSet.PermissionDenied, from_errno(c.EACCES));
    try std.testing.expectEqual(ErrnoSet.BadAddress, from_errno(c.EFAULT));
    try std.testing.expectEqual(ErrnoSet.BlockDeviceRequired, from_errno(c.ENOTBLK));
    try std.testing.expectEqual(ErrnoSet.DeviceOrResourceBusy, from_errno(c.EBUSY));
    try std.testing.expectEqual(ErrnoSet.FileExists, from_errno(c.EEXIST));
    try std.testing.expectEqual(ErrnoSet.CrossDeviceLink, from_errno(c.EXDEV));
    try std.testing.expectEqual(ErrnoSet.NoSuchDevice, from_errno(c.ENODEV));
    try std.testing.expectEqual(ErrnoSet.NotADirectory, from_errno(c.ENOTDIR));
    try std.testing.expectEqual(ErrnoSet.IsADirectory, from_errno(c.EISDIR));
    try std.testing.expectEqual(ErrnoSet.InvalidArgument, from_errno(c.EINVAL));
    try std.testing.expectEqual(ErrnoSet.FileTableOverflow, from_errno(c.ENFILE));
    try std.testing.expectEqual(ErrnoSet.TooManyOpenFiles, from_errno(c.EMFILE));
    try std.testing.expectEqual(ErrnoSet.NotTypeWriter, from_errno(c.ENOTTY));
    try std.testing.expectEqual(ErrnoSet.TextFileBusy, from_errno(c.ETXTBSY));
    try std.testing.expectEqual(ErrnoSet.FileTooLarge, from_errno(c.EFBIG));
    try std.testing.expectEqual(ErrnoSet.NoSpaceLeftOnDevice, from_errno(c.ENOSPC));
    try std.testing.expectEqual(ErrnoSet.IllegalSeek, from_errno(c.ESPIPE));
    try std.testing.expectEqual(ErrnoSet.ReadOnlyFileSystem, from_errno(c.EROFS));
    try std.testing.expectEqual(ErrnoSet.TooManyLinks, from_errno(c.EMLINK));
    try std.testing.expectEqual(ErrnoSet.BrokenPipe, from_errno(c.EPIPE));
    try std.testing.expectEqual(ErrnoSet.MathArgumentOutOfDomain, from_errno(c.EDOM));
    try std.testing.expectEqual(ErrnoSet.MathResultNotRepresentable, from_errno(c.ERANGE));
    try std.testing.expectEqual(ErrnoSet.TooManySymbolicLinks, from_errno(c.ELOOP));
    try std.testing.expectEqual(ErrnoSet.NotImplemented, from_errno(c.ENOSYS));
}

test "Errno.ShouldReturnInvalidForUnknownErrno" {
    try std.testing.expectEqual(ErrnoSet.Invalid, from_errno(9999));
    try std.testing.expectEqual(ErrnoSet.Invalid, from_errno(0));
}

test "Errno.ShouldConvertFromErrorSetToErrno" {
    try std.testing.expectEqual(@as(u16, c.EPERM), to_errno(ErrnoSet.NotPermitted));
    try std.testing.expectEqual(@as(u16, c.ENOENT), to_errno(ErrnoSet.NoEntry));
    try std.testing.expectEqual(@as(u16, c.ESRCH), to_errno(ErrnoSet.NoSuchProcess));
    try std.testing.expectEqual(@as(u16, c.EINTR), to_errno(ErrnoSet.InterruptedSystemCall));
    try std.testing.expectEqual(@as(u16, c.EIO), to_errno(ErrnoSet.InputOutputError));
    try std.testing.expectEqual(@as(u16, c.ENXIO), to_errno(ErrnoSet.NoSuchDeviceOrAddress));
    try std.testing.expectEqual(@as(u16, c.E2BIG), to_errno(ErrnoSet.ArgumentListTooLong));
    try std.testing.expectEqual(@as(u16, c.ENOEXEC), to_errno(ErrnoSet.ExecFormatError));
    try std.testing.expectEqual(@as(u16, c.EBADF), to_errno(ErrnoSet.BadFileDescriptor));
    try std.testing.expectEqual(@as(u16, c.ECHILD), to_errno(ErrnoSet.NoChildProcesses));
    try std.testing.expectEqual(@as(u16, c.EAGAIN), to_errno(ErrnoSet.TryAgain));
    try std.testing.expectEqual(@as(u16, c.ENOMEM), to_errno(ErrnoSet.OutOfMemory));
    try std.testing.expectEqual(@as(u16, c.EACCES), to_errno(ErrnoSet.PermissionDenied));
    try std.testing.expectEqual(@as(u16, c.EFAULT), to_errno(ErrnoSet.BadAddress));
    try std.testing.expectEqual(@as(u16, c.ENOTBLK), to_errno(ErrnoSet.BlockDeviceRequired));
    try std.testing.expectEqual(@as(u16, c.EBUSY), to_errno(ErrnoSet.DeviceOrResourceBusy));
    try std.testing.expectEqual(@as(u16, c.EEXIST), to_errno(ErrnoSet.FileExists));
    try std.testing.expectEqual(@as(u16, c.EXDEV), to_errno(ErrnoSet.CrossDeviceLink));
    try std.testing.expectEqual(@as(u16, c.ENODEV), to_errno(ErrnoSet.NoSuchDevice));
    try std.testing.expectEqual(@as(u16, c.ENOTDIR), to_errno(ErrnoSet.NotADirectory));
    try std.testing.expectEqual(@as(u16, c.EISDIR), to_errno(ErrnoSet.IsADirectory));
    try std.testing.expectEqual(@as(u16, c.EINVAL), to_errno(ErrnoSet.InvalidArgument));
    try std.testing.expectEqual(@as(u16, c.ENFILE), to_errno(ErrnoSet.FileTableOverflow));
    try std.testing.expectEqual(@as(u16, c.EMFILE), to_errno(ErrnoSet.TooManyOpenFiles));
    try std.testing.expectEqual(@as(u16, c.ENOTTY), to_errno(ErrnoSet.NotTypeWriter));
    try std.testing.expectEqual(@as(u16, c.ETXTBSY), to_errno(ErrnoSet.TextFileBusy));
    try std.testing.expectEqual(@as(u16, c.EFBIG), to_errno(ErrnoSet.FileTooLarge));
    try std.testing.expectEqual(@as(u16, c.ENOSPC), to_errno(ErrnoSet.NoSpaceLeftOnDevice));
    try std.testing.expectEqual(@as(u16, c.ESPIPE), to_errno(ErrnoSet.IllegalSeek));
    try std.testing.expectEqual(@as(u16, c.EROFS), to_errno(ErrnoSet.ReadOnlyFileSystem));
    try std.testing.expectEqual(@as(u16, c.EMLINK), to_errno(ErrnoSet.TooManyLinks));
    try std.testing.expectEqual(@as(u16, c.EPIPE), to_errno(ErrnoSet.BrokenPipe));
    try std.testing.expectEqual(@as(u16, c.EDOM), to_errno(ErrnoSet.MathArgumentOutOfDomain));
    try std.testing.expectEqual(@as(u16, c.ERANGE), to_errno(ErrnoSet.MathResultNotRepresentable));
    try std.testing.expectEqual(@as(u16, c.ELOOP), to_errno(ErrnoSet.TooManySymbolicLinks));
    try std.testing.expectEqual(@as(u16, c.ENOSYS), to_errno(ErrnoSet.NotImplemented));
}

test "Errno.ShouldReturnEINVALForUnknownError" {
    try std.testing.expectEqual(@as(u16, c.EINVAL), to_errno(ErrnoSet.Invalid));
    try std.testing.expectEqual(@as(u16, c.EINVAL), to_errno(error.SomeRandomError));
}

test "Errno.ShouldRoundTripConversion" {
    const test_cases = [_]u16{
        c.EPERM,
        c.ENOENT,
        c.ESRCH,
        c.EINTR,
        c.EIO,
        c.ENXIO,
        c.E2BIG,
        c.ENOEXEC,
        c.EBADF,
        c.ECHILD,
        c.EAGAIN,
        c.ENOMEM,
        c.EACCES,
        c.EFAULT,
        c.ENOTBLK,
        c.EBUSY,
        c.EEXIST,
        c.EXDEV,
        c.ENODEV,
        c.ENOTDIR,
        c.EISDIR,
        c.EINVAL,
        c.ENFILE,
        c.EMFILE,
        c.ENOTTY,
        c.ETXTBSY,
        c.EFBIG,
        c.ENOSPC,
        c.ESPIPE,
        c.EROFS,
        c.EMLINK,
        c.EPIPE,
        c.EDOM,
        c.ERANGE,
        c.ELOOP,
        c.ENOSYS,
    };

    for (test_cases) |errno_val| {
        const err = from_errno(errno_val);
        const converted_back = to_errno(err);
        try std.testing.expectEqual(errno_val, converted_back);
    }
}

