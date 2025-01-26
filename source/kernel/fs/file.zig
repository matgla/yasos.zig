//
// file.zig
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

const c = @cImport({
    @cInclude("unistd.h");
});

const File = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    read: *const fn (ctx: *anyopaque, buf: []u8, size: usize) isize,
    write: *const fn (ctx: *anyopaque, buf: []const u8, size: usize) isize,
    seek: *const fn (ctx: *anyopaque, offset: c.off_t, base: i32) c.off_t,
    close: *const fn (ctx: *anyopaque) i32,
    sync: *const fn (ctx: *anyopaque) i32,
    tell: *const fn (ctx: *anyopaque) c.off_t,
    size: *const fn (ctx: *anyopaque) isize,
    name: *const fn (ctx: *anyopaque) []const u8,
    ioctl: *const fn (ctx: *anyopaque, cmd: u32, arg: *anyopaque) i32,
    stat: *const fn (ctx: *anyopaque, data: *c.state) void,
};

pub inline fn read(self: File, buf: []u8, count: usize) isize {
    return self.vtable.read(self.ptr, buf, count);
}

pub inline fn write(self: File, buf: []const u8, count: usize) isize {
    return self.vtable.write(buf, count);
}
pub inline fn seek(self: File, offset: c.off_t, base: i32) c.off_t {
    return self.vtable.seek(offset, base);
}

pub inline fn close(self: File) i32 {
    return self.vtable.close();
}

pub inline fn sync(self: File) i32 {
    return self.vtable.sync();
}

pub inline fn tell(self: File) c.off_t {
    return self.vtable.tell();
}

pub inline fn size(self: File) isize {
    return self.vtable.size();
}

pub inline fn name(self: File) []const u8 {
    return self.vtable.name();
}

pub inline fn ioctl(self: File, cmd: u32, arg: *anyopaque) i32 {
    return self.vtable.ioctl(cmd, arg);
}

pub inline fn stat(self: File, data: *c.state) void {
    return self.vtable.stat(data);
}
