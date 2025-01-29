//
// filesystem.zig
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

const IFile = @import("ifile.zig").IFile;

pub const IFileSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mount: *const fn (ctx: *anyopaque) i32,
        umount: *const fn (ctx: *anyopaque) i32,
        create: *const fn (ctx: *anyopaque, path: []const u8, flags: i32) i32,
        mkdir: *const fn (ctx: *anyopaque, path: []const u8, mode: i32) i32,
        remove: *const fn (ctx: *anyopaque, path: []const u8) i32,
        name: *const fn (ctx: *const anyopaque) []const u8,
        traverse: *const fn (ctx: *const anyopaque, path: []const u8, callback: *const fn (file: *IFile) void) i32,
        get: *const fn (ctx: *anyopaque, path: []const u8) ?IFile,

        has_path: *const fn (ctx: *anyopaque, path: []const u8) bool,
    };

    pub fn mount(self: IFileSystem) void {
        self.vtable.mount(self.ptr);
    }

    pub fn umount(self: IFileSystem) i32 {
        return self.vtable.umount(self.ptr);
    }

    pub fn create(self: IFileSystem, path: []const u8, flags: i32) i32 {
        return self.vtable.create(self.ptr, path, flags);
    }

    pub fn mkdir(self: IFileSystem, path: []const u8, mode: i32) i32 {
        return self.vtable.mkdir(self.ptr, path, mode);
    }

    pub fn remove(self: IFileSystem, path: []const u8) i32 {
        return self.vtable.remove(self.ptr, path);
    }

    pub fn name(self: IFileSystem) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn traverse(self: IFileSystem, path: []const u8, callback: *const fn (file: *IFile) void) i32 {
        return self.vtable.traverse(self.ptr, path, callback);
    }

    pub fn get(self: IFileSystem, path: []const u8) ?IFile {
        return self.vtable.get(self.ptr, path);
    }

    pub fn has_path(self: IFileSystem, path: []const u8) bool {
        return self.vtable.has_path(self.ptr, path);
    }
};
