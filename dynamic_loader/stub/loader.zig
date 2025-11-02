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

const std = @import("std");

const Module = @import("module.zig").Module;
const Executable = @import("executable.zig").Executable;

pub const Loader = struct {
    pub const FileResolver = *const fn (name: []const u8) ?*const anyopaque;
    file_resolver: FileResolver,
    allocator: std.mem.Allocator,

    load_error: ?anyerror,

    pub fn create(file_resolver: FileResolver, allocator: std.mem.Allocator) Loader {
        return Loader{
            .file_resolver = file_resolver,
            .allocator = allocator,
            .load_error = null,
        };
    }

    pub fn deinit(self: *Loader) void {
        _ = self;
    }

    pub fn load_should_fail(self: *Loader, err: anyerror) void {
        self.load_error = err;
    }
    pub fn load_should_succeed(self: *Loader) void {
        self.load_error = null;
    }

    pub fn load_executable(self: *Loader, module: *const anyopaque, process_allocator: std.mem.Allocator) !Executable {
        _ = module;
        if (self.load_error) |err| {
            self.load_error = null;
            return err;
        }
        return .{
            .module = try Module.create(std.heap.page_allocator, process_allocator, false),
        };
    }

    pub fn load_library(self: *Loader, module: *const anyopaque, process_allocator: std.mem.Allocator) !*Module {
        _ = module;
        if (self.load_error) |err| {
            self.load_error = null;
            return err;
        }
        const module_obj = Module.create(std.heap.page_allocator, process_allocator, false);
        return module_obj;
    }

    pub fn unload_module(self: *Loader, module: *Module) void {
        _ = self;
        _ = module;
    }
};

var loader_object: ?Loader = null;

pub fn init(file_resolver: anytype, allocator: std.mem.Allocator) void {
    loader_object = Loader.create(file_resolver, allocator);
}

pub fn deinit() void {
    if (loader_object) |*loader| {
        loader.deinit();
        loader_object = null;
    }
}

pub fn get_loader() ?*Loader {
    if (loader_object) |*loader| {
        return loader;
    }
    return null;
}
