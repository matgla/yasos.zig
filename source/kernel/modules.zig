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
    name: []const u8,
    address: ?*const anyopaque,
};

const kernel = @import("kernel.zig");

const log = std.log.scoped(.loader);

fn file_resolver(name: []const u8) ?*const anyopaque {
    var context: ModuleContext = .{
        .name = name,
        .address = null,
    };

    var maybe_node = fs.get_ivfs().interface.get("/lib") catch null;
    if (maybe_node) |*node| {
        defer node.delete();
        var maybe_dir = node.as_directory();
        if (maybe_dir) |*dir| {
            var it = dir.interface.iterator() catch return null;
            defer it.interface.delete();
            while (it.interface.next()) |*entry| {
                var filenode: kernel.fs.Node = undefined;
                dir.interface.get(entry.name, &filenode) catch continue;
                defer filenode.delete();
                if (filenode.as_file()) |f| {
                    if (is_requested_file(f, &context)) {
                        break;
                    }
                }
            }
        }
    }

    if (context.address) |address| {
        return address;
    }
    return null;
}

fn is_requested_file(file: kernel.fs.IFile, context: *ModuleContext) bool {
    if (std.mem.eql(u8, context.name, file.interface.name())) {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };

        var fc: kernel.fs.IFile = file;
        _ = fc.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        if (attr.mapped_address_r) |address| {
            context.address = address;
            return true;
        }
    }
    return false;
}

const ExecutableHandle = struct {
    allocator: std.mem.Allocator,
    executable: ?yasld.Executable,
    memory: ?[]align(16) u8,
};

var modules_list: std.AutoHashMap(c.pid_t, ExecutableHandle) = undefined;
var libraries_list: std.AutoHashMap(c.pid_t, std.DoublyLinkedList) = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    log.info("yasld initialization started", .{});
    yasld.loader_init(&file_resolver, allocator);
    modules_list = std.AutoHashMap(c.pid_t, ExecutableHandle).init(allocator);
    libraries_list = std.AutoHashMap(c.pid_t, std.DoublyLinkedList).init(allocator);
    kernel_allocator = allocator;
}

pub fn deinit() void {
    var it = modules_list.iterator();
    while (it.next()) |item| {
        if (item.value_ptr.memory) |mem| {
            item.value_ptr.allocator.free(mem);
        }
    }
    modules_list.deinit();
    libraries_list.deinit();
    yasld.loader_deinit();
}

pub fn load_executable(path: []const u8, process_allocator: std.mem.Allocator, pid: c.pid_t) !*yasld.Executable {
    var node = try fs.get_ivfs().interface.get(path);
    defer node.delete();
    var maybe_file = node.as_file();
    if (maybe_file) |*f| {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = f.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        var header_address: *const anyopaque = undefined;
        var entry = ExecutableHandle{
            .allocator = process_allocator,
            .executable = null,
            .memory = null,
        };
        if (attr.mapped_address_r) |address| {
            header_address = address;
        } else {
            var memory: []align(16) u8 = try process_allocator.alignedAlloc(u8, .@"16", f.interface.size());
            header_address = @ptrCast(&memory[0]);
            entry.memory = memory;
            _ = f.interface.read(memory);
        }
        if (yasld.get_loader()) |loader| {
            const executable = loader.*.load_executable(header_address, process_allocator) catch |err| {
                log.err("loading '{s}' failed: {s}", .{ path, @errorName(err) });
                return err;
            };
            release_executable(pid);
            entry.executable = executable;
            modules_list.put(pid, entry) catch |err| return err;
            const exec_ptr: *yasld.Executable = &modules_list.getPtr(pid).?.executable.?;
            return exec_ptr;
        } else {
            log.err("yasld is not initialized", .{});
            return kernel.errno.ErrnoSet.NotPermitted;
        }
    }
    return kernel.errno.ErrnoSet.IsADirectory;
}

pub fn load_shared_library(path: []const u8, process_allocator: std.mem.Allocator, pid: c.pid_t) !*yasld.Module {
    var node = try fs.get_ivfs().interface.get(path);
    defer node.delete();
    var maybe_file = node.as_file();
    if (maybe_file) |*f| {
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
            return kernel.errno.ErrnoSet.NotPermitted;
        }
    }
    return kernel.errno.ErrnoSet.IsADirectory;
}

pub fn release_executable(pid: c.pid_t) void {
    var maybe_entry = modules_list.getPtr(pid);
    if (maybe_entry) |*entry| {
        if (entry.*.executable) |*executable| {
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
        }
        _ = libraries_list.remove(pid);
    }
}

pub fn release_shared_library(pid: c.pid_t, library: *yasld.Module) void {
    const maybe_list = libraries_list.getPtr(pid);
    if (maybe_list) |list| {
        list.remove(&library.list_node);
        if (yasld.get_loader()) |loader| {
            loader.*.unload_module(library);
        }
        if (list.first == null) {
            _ = libraries_list.remove(pid);
        }
    }
}

pub fn get_executable_for_pid(pid: c.pid_t) ?*yasld.Executable {
    if (!modules_list.contains(pid)) {
        return null;
    }
    if (modules_list.getPtr(pid).?.executable) |*exec| {
        return exec;
    }
    return null;
}

test "Modules.ShouldInitializeAndDeinitialize" {
    init(std.testing.allocator);
    defer deinit();

    try std.testing.expect(modules_list.count() == 0);
    try std.testing.expect(libraries_list.count() == 0);
}

const FileSystemMock = @import("fs/tests/filesystem_mock.zig").FileSystemMock;
fn create_vfs_for_test(allocator: std.mem.Allocator) !*FileSystemMock {
    var fs_mock = try FileSystemMock.create(allocator);
    defer fs_mock.delete();
    kernel.fs.vfs_init(allocator);
    try fs.get_vfs().mount_filesystem("/", fs_mock.get_interface());
    return fs_mock;
}

const FileMock = @import("fs/tests/file_mock.zig").FileMock;
const interface = @import("interface");
const test_mapped_address: usize = 0x1000;
fn create_filemock(allocator: std.mem.Allocator) !*FileMock {
    var file_mock = try FileMock.create(allocator);
    const IoctlCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: std.meta.Tuple(&[_]type{ i32, ?*anyopaque })) !i32 {
            const cmd = args[0];
            try std.testing.expectEqual(cmd, @as(i32, @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus)));

            const a = args[1];
            var attr: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(a.?));
            attr.is_memory_mapped = true;
            attr.mapped_address_w = null;
            attr.mapped_address_r = ctx.?;
            return 0;
        }
    };

    _ = file_mock
        .expectCall("ioctl")
        .invoke(&IoctlCallback.call, &test_mapped_address)
        .times(interface.mock.any{})
        .willReturn(0);

    return file_mock;
}

test "Modules.ShouldLoadExecutableFromFileSystem" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    // Create a mock ELF file
    var file_mock = try create_filemock(std.testing.allocator);
    const file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(file_node);

    const pid: c.pid_t = 123;
    _ = try load_executable("/test_executable", std.testing.allocator, pid);

    try std.testing.expect(get_executable_for_pid(pid) != null);
    release_executable(pid);

    try std.testing.expect(get_executable_for_pid(pid) == null);
}

test "Modules.ShouldLoadSharedLibrariesFromFileSystem" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    // Create a mock ELF file
    var file_mock = try create_filemock(std.testing.allocator);
    const file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_lib"})
        .willReturn(file_node);

    const pid: c.pid_t = 123;
    const lib = try load_shared_library("/test_lib", std.testing.allocator, pid);

    try std.testing.expect(get_executable_for_pid(pid) == null);
    try std.testing.expect(libraries_list.getPtr(pid) != null);
    try std.testing.expect(libraries_list.getPtr(pid).?.len() == 1);
    release_shared_library(pid, lib);

    try std.testing.expect(get_executable_for_pid(pid) == null);
    try std.testing.expect(libraries_list.getPtr(pid) == null);
}

test "Modules.ShouldHandleExecutableDependantOnSharedLibraries" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    // Create a mock ELF file
    var file_mock = try create_filemock(std.testing.allocator);
    const file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(file_node);

    var lib1_mock = try create_filemock(std.testing.allocator);
    const lib1_node = kernel.fs.Node.create_file(lib1_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"libdependency1.so"})
        .willReturn(lib1_node);

    var lib2_mock = try create_filemock(std.testing.allocator);
    const lib2_node = kernel.fs.Node.create_file(lib2_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"libdependency2.so"})
        .willReturn(lib2_node);

    const pid: c.pid_t = 123;
    _ = try load_executable("/test_executable", std.testing.allocator, pid);
    _ = try load_shared_library("/libdependency1.so", std.testing.allocator, pid);
    _ = try load_shared_library("/libdependency2.so", std.testing.allocator, pid);

    try std.testing.expect(get_executable_for_pid(pid) != null);
    const libs = libraries_list.getPtr(pid);
    try std.testing.expect(libs != null);
    try std.testing.expect(libs.?.len() == 2);
    release_executable(pid);

    try std.testing.expect(get_executable_for_pid(pid) == null);
    try std.testing.expectEqual(null, libraries_list.getPtr(pid));
}

test "Modules.ShouldForwardLoadingErrors" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    // Create a mock ELF file
    var file_mock = try create_filemock(std.testing.allocator);
    const file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(file_node);

    const pid: c.pid_t = 123;
    yasld.get_loader().?.load_should_fail(kernel.errno.ErrnoSet.ExecFormatError);
    try std.testing.expectError(kernel.errno.ErrnoSet.ExecFormatError, load_executable("/test_executable", std.testing.allocator, pid));
}

const DirectoryMock = @import("fs/tests/directory_mock.zig").DirectoryMock;
test "Modules.ShouldFailIfDirectoryProvidedInsteadOfFile" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(dirnode);

    var dirmock2 = try DirectoryMock.create(std.testing.allocator);
    const dirnode2 = kernel.fs.Node.create_directory(dirmock2.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(dirnode2);

    const pid: c.pid_t = 123;
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, load_executable("/test_executable", std.testing.allocator, pid));
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, load_shared_library("/test_executable", std.testing.allocator, pid));
}

test "Modules.ShouldFailIfDynamicLoaderUninitialized" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var file_mock = try create_filemock(std.testing.allocator);
    const filenode1 = kernel.fs.Node.create_file(file_mock.get_interface());
    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(filenode1);

    var filemock2 = try create_filemock(std.testing.allocator);
    const filenode2 = kernel.fs.Node.create_file(filemock2.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(filenode2);

    const pid: c.pid_t = 123;
    yasld.loader_deinit();
    try std.testing.expectError(kernel.errno.ErrnoSet.NotPermitted, load_executable("/test_executable", std.testing.allocator, pid));
    try std.testing.expectError(kernel.errno.ErrnoSet.NotPermitted, load_shared_library("/test_executable", std.testing.allocator, pid));
}

const DirectoryIteratorMock = @import("fs/tests/directory_mock.zig").DirectoryIteratorMock;

test "Modules.ResolverShouldReturnNullIfFileNotFoundInFileSystem" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    try std.testing.expectEqual(null, file_resolver("libtest.so"));
}

test "Modules.ResolverShouldReturnNullIfIteratorCreationFails" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    try std.testing.expectEqual(null, file_resolver("libtest.so"));
}

test "Modules.ResolverShouldReturnNullIfFileNotFoundInDirectory" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    var itmock = try DirectoryIteratorMock.create(std.testing.allocator);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(itmock.get_interface());

    _ = itmock
        .expectCall("next")
        .willReturn(null);

    try std.testing.expectEqual(null, file_resolver("libtest.so"));
}

test "Modules.ResolverShouldReturnAddressIfFileFoundInDirectory" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    var itmock = try DirectoryIteratorMock.create(std.testing.allocator);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(itmock.get_interface());

    _ = itmock
        .expectCall("next")
        .willReturn(.{
        .name = "libtest.so",
        .kind = .File,
    });

    var file_mock = try create_filemock(std.testing.allocator);
    const filenode = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = file_mock
        .expectCall("name")
        .willReturn("libtest.so");

    const GetCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: std.meta.Tuple(&[_]type{ []const u8, *kernel.fs.Node })) anyerror!anyerror!void {
            const node_name = args[0];
            const node = args[1];
            node.* = @as(*const kernel.fs.Node, @ptrCast(@alignCast(ctx))).*;
            try std.testing.expectEqualSlices(u8, node_name, "libtest.so");
        }
    };
    _ = dirmock
        .expectCall("get")
        .withArgs(.{"libtest.so"})
        .invoke(&GetCallback.call, &filenode);

    try std.testing.expectEqual(@as(*const anyopaque, &test_mapped_address), file_resolver("libtest.so"));
}

test "Modules.ResolverShouldReturnNullIfFileIsNotMemoryMapped" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    var itmock = try DirectoryIteratorMock.create(std.testing.allocator);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(itmock.get_interface());

    _ = itmock
        .expectCall("next")
        .willReturn(.{
        .name = "libtest.so",
        .kind = .File,
    });

    _ = itmock
        .expectCall("next")
        .willReturn(null);

    var filemock = try FileMock.create(std.testing.allocator);

    const filenode = kernel.fs.Node.create_file(filemock.get_interface());
    _ = filemock
        .expectCall("ioctl")
        .withArgs(.{ @as(i32, @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus)), interface.mock.any{} })
        .willReturn(0);

    _ = filemock
        .expectCall("name")
        .willReturn("libtest.so");

    const GetCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: std.meta.Tuple(&[_]type{ []const u8, *kernel.fs.Node })) anyerror!anyerror!void {
            const node_name = args[0];
            const node = args[1];
            node.* = @as(*const kernel.fs.Node, @ptrCast(@alignCast(ctx))).*;
            try std.testing.expectEqualSlices(u8, node_name, "libtest.so");
        }
    };
    _ = dirmock
        .expectCall("get")
        .withArgs(.{"libtest.so"})
        .invoke(&GetCallback.call, &filenode);

    try std.testing.expectEqual(null, file_resolver("libtest.so"));
}
