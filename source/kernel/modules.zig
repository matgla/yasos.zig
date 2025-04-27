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

// This file contains preconfigured dynamic loader for the kernel.
// It keeps track of loaded modules and their addresses, for further deallocation when died.

const std = @import("std");

const yasld = @import("yasld");

const IFile = @import("fs/fs.zig").IFile;
const fs = @import("fs/vfs.zig");
const FileMemoryMapAttributes = @import("fs/ifile.zig").FileMemoryMapAttributes;
const IoctlCommonCommands = @import("fs/ifile.zig").IoctlCommonCommands;

var null_log = &@import("../log/kernel_log.zig").null_log;
const log = &@import("../log/kernel_log.zig").kernel_log;

const ModuleContext = struct {
    path: []const u8,
    address: ?*const anyopaque,
};

fn file_resolver(name: []const u8) ?*const anyopaque {
    var context: ModuleContext = .{
        .path = name,
        .address = null,
    };
    _ = fs.ivfs().traverse("/lib", traverse_directory, &context);
    if (context.address) |address| {
        return address;
    }
    return null;
}

fn traverse_directory(file: *IFile, context: *anyopaque) bool {
    var module_context: *ModuleContext = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, module_context.path, file.name())) {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = file.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        if (attr.mapped_address_r) |address| {
            module_context.address = address;
            return false;
        }
    }
    return true;
}

var modules_list: std.AutoHashMap(u32, yasld.Executable) = undefined;
var loader: yasld.Loader = undefined;

pub fn init(kernel_allocator: std.mem.Allocator) void {
    loader = yasld.Loader.create(&file_resolver);
    modules_list = std.AutoHashMap(u32, yasld.Executable).init(kernel_allocator);
}

pub fn load_executable(path: []const u8, allocator: std.mem.Allocator, pid: u32) !*yasld.Executable {
    const maybe_file = fs.ivfs().get(path);
    if (maybe_file) |f| {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = f.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        f.destroy();
        var header_address: *const anyopaque = undefined;

        if (attr.mapped_address_r) |address| {
            header_address = address;
        } else {
            // copy file to memory before running
            @panic("Implement image copying to memory");
        }
        const executable = loader.load_executable(header_address, null_log, allocator) catch |err| {
            return err;
        };
        if (modules_list.getPtr(pid)) |prev| {
            prev.deinit();
            _ = modules_list.remove(pid);
        }
        modules_list.put(pid, executable) catch |err| return err;
        const exec_ptr: *yasld.Executable = modules_list.getPtr(pid).?;
        return exec_ptr;
    }
    return std.posix.AccessError.FileNotFound;
}

pub fn release_executable(pid: u32) void {
    const maybe_executable = modules_list.getPtr(pid);
    if (maybe_executable) |executable| {
        executable.deinit();
        _ = modules_list.remove(pid);
    }
}
