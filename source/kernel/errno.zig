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

const c = @import("libc_imports");

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

pub fn to_errno(err: ErrnoSet) u16 {
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
