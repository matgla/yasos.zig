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

const c = @import("libc_imports").c;

var kernel_allocator: std.mem.Allocator = undefined;

const ModuleContext = struct {
    path: []const u8,
    address: ?*const anyopaque,
};

const kernel = @import("kernel");
const log = std.log.scoped(.loader);

fn file_resolver(name: []const u8) ?*const anyopaque {
    var context: ModuleContext = .{
        .path = name,
        .address = null,
    };
    _ = fs.get_ivfs().interface.traverse("/lib", traverse_directory, &context);
    if (context.address) |address| {
        return address;
    }
    return null;
}

fn traverse_directory(file: *IFile, context: *anyopaque) bool {
    var module_context: *ModuleContext = @ptrCast(@alignCast(context));
    const filename = file.interface.name();
    if (std.mem.eql(u8, module_context.path, filename)) {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = file.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        if (attr.mapped_address_r) |address| {
            module_context.address = address;
            return false;
        }
    }
    return true;
}

var modules_list: std.AutoHashMap(c.pid_t, yasld.Executable) = undefined;
var libraries_list: std.AutoHashMap(c.pid_t, std.DoublyLinkedList) = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    log.info("yasld initialization started", .{});
    yasld.loader_init(&file_resolver, allocator);
    modules_list = std.AutoHashMap(c.pid_t, yasld.Executable).init(allocator);
    libraries_list = std.AutoHashMap(c.pid_t, std.DoublyLinkedList).init(allocator);
    kernel_allocator = allocator;
}

pub fn deinit() void {
    modules_list.deinit();
    libraries_list.deinit();
    yasld.loader_deinit();
}

pub fn load_executable(path: []const u8, allocator: std.mem.Allocator, process_allocator: std.mem.Allocator, pid: c.pid_t) !*yasld.Executable {
    var maybe_node = fs.get_ivfs().interface.get(path, allocator);
    if (maybe_node == null) {
        return std.posix.AccessError.FileNotFound;
    }
    defer maybe_node.?.delete();
    var maybe_file = maybe_node.?.as_file();
    if (maybe_file) |*f| {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = f.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        var header_address: *const anyopaque = undefined;

        if (attr.mapped_address_r) |address| {
            header_address = address;
        } else {
            // copy file to memory before running
            @panic("Implement image copying to memory");
        }
        if (yasld.get_loader()) |loader| {
            // const loader_logger = log;
            // loader_logger.debug_enabled = false;
            // loader_logger.prefix = "[yasld]";
            const executable = loader.*.load_executable(header_address, process_allocator) catch |err| {
                log.err("loading '{s}' failed: {s}", .{ path, @errorName(err) });
                return err;
            };
            if (modules_list.getPtr(pid)) |prev| {
                prev.deinit();
                _ = modules_list.remove(pid);
            }
            modules_list.put(pid, executable) catch |err| return err;
            const exec_ptr: *yasld.Executable = modules_list.getPtr(pid).?;
            return exec_ptr;
        } else {
            log.err("yasld is not initialized", .{});
        }
    }
    return std.posix.AccessError.FileNotFound;
}

pub fn load_shared_library(path: []const u8, allocator: std.mem.Allocator, process_allocator: std.mem.Allocator, pid: c.pid_t) !*yasld.Module {
    var maybe_node = fs.get_ivfs().interface.get(path, allocator);
    if (maybe_node == null) {
        return std.posix.AccessError.FileNotFound;
    }
    var maybe_file = maybe_node.?.as_file();
    if (maybe_file) |*f| {
        defer f.interface.delete();
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = f.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        // f.destroy();
        var header_address: *const anyopaque = undefined;

        if (attr.mapped_address_r) |address| {
            header_address = address;
        } else {
            // copy file to memory before running
            @panic("Implement image copying to memory");
        }
        if (yasld.get_loader()) |loader| {
            const library = loader.*.load_library(header_address, process_allocator) catch |err| {
                return err;
            };

            if (!libraries_list.contains(pid)) {
                libraries_list.put(pid, .{}) catch |err| return err;
            }
            const maybe_list = libraries_list.getPtr(pid);
            if (maybe_list) |list| {
                list.append(&library.list_node);
            }
            return library;
        } else {
            log.err("yasld is not initialized", .{});
        }
    }
    return std.posix.AccessError.FileNotFound;
}

pub fn release_executable(pid: c.pid_t) void {
    const maybe_executable = modules_list.getPtr(pid);
    if (maybe_executable) |executable| {
        executable.deinit();
        _ = modules_list.remove(pid);
        const maybe_list = libraries_list.getPtr(pid);
        if (maybe_list) |list| {
            var next = list.pop();
            while (next) |node| {
                const library: *yasld.Module = @fieldParentPtr("list_node", node);
                library.destroy();
                next = list.pop();
            }
        }
        _ = libraries_list.remove(pid);
    }
}

pub fn release_shared_library(pid: c.pid_t, library: *yasld.Module) void {
    const maybe_list = libraries_list.getPtr(pid);
    if (maybe_list) |*list| {
        list.*.remove(&library.list_node);
        if (yasld.get_loader()) |loader| {
            loader.*.unload_module(library);
        }
    }
}
