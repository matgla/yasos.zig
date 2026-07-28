//
// display_file.zig
//
// `/dev/fb0` — the character device in front of a hal display.
//
// Everything here is deliberately expressed in terms of the placement-agnostic
// hal/interface/display.zig contract (begin_frame -> commit -> present), so the
// same node works whether the framebuffer is host-mmap'd RAM under QEMU, PSRAM
// scanned out by a second core, or memory that only exists on an extension
// board at the far end of a link.
//
// Usage from userspace:
//   ioctl(fd, YASFB_SET_MODE, &(struct yasfb_mode){640, 480, YASFB_FMT_RGB332});
//   ioctl(fd, YASFB_GET_INFO, &info);
//   write(fd, pixels, info.stride * info.height);   // a full frame auto-presents
//   ioctl(fd, YASFB_POLL_EVENT, &event);            // 1 = got one, 0 = queue empty
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

const std = @import("std");

const hal = @import("hal");

const kernel = @import("../../kernel.zig");

const IFile = @import("../../fs/ifile.zig").IFile;
const FileType = @import("../../fs/ifile.zig").FileType;

const interface = @import("interface");

// ioctl opcodes. Mirrored in rootfs/usr/include/yasos/fb.h — keep in sync.
//
// Magic 0x59 ('Y' for yasos), deliberately NOT Linux's fbdev range 0x46xx ('F').
// This is not a Linux framebuffer and the structs below are not Linux's, so
// sharing its opcodes would make a ported program calling FBIOGET_VSCREENINFO
// (0x4600) land on YASFB_GET_INFO, get 24 bytes of yasfb_info written into its
// 160-byte fb_var_screeninfo, and see a 0 return — silent garbage. On a private
// magic the same call falls through to the `else` below and fails with -1,
// which is an obvious, debuggable answer to "we do not implement that".
//
// 0x54xx is already the termios range (rootfs/usr/include/sys/ioctl.h), which
// IS intentionally Linux-compatible; that asymmetry is fine, because there the
// structs match too.
pub const YASFB_GET_INFO: i32 = 0x5900;
pub const YASFB_SET_MODE: i32 = 0x5901;
pub const YASFB_PRESENT: i32 = 0x5902;
pub const YASFB_POLL_EVENT: i32 = 0x5903;

pub const Info = extern struct {
    width: u32,
    height: u32,
    stride: u32,
    bits_per_pixel: u32,
    format: u32,
    buffer_count: u32,
};

pub const ModeRequest = extern struct {
    width: u32,
    height: u32,
    format: u32,
};

pub fn DisplayFile(comptime DisplayType: type) type {
    const Internal = struct {
        const DisplayFileImpl = interface.DeriveFromBase(IFile, struct {
            const Self = @This();

            _display: *DisplayType,
            _allocator: std.mem.Allocator,
            _name: []const u8,
            // Write cursor inside the frame, in bytes. Lets a plain
            // `write()`/`lseek()` stream pixels without any ioctl at all.
            _offset: usize,

            pub fn delete(self: *Self) void {
                _ = self;
            }

            pub fn create(allocator: std.mem.Allocator, display: *DisplayType, filename: []const u8) DisplayFileImpl {
                return DisplayFileImpl.init(.{
                    ._display = display,
                    ._allocator = allocator,
                    ._name = filename,
                    ._offset = 0,
                });
            }

            pub fn create_node(allocator: std.mem.Allocator, display: *DisplayType, filename: []const u8) anyerror!kernel.fs.Node {
                const file = try create(allocator, display, filename).interface.new(allocator);
                return kernel.fs.Node.create_file(file);
            }

            fn frame_size(self: *const Self) usize {
                const m = self._display.mode() orelse return 0;
                return @as(usize, m.width) * m.height * m.format.bytes_per_pixel();
            }

            pub fn read(self: *Self, buffer: []u8) isize {
                // Reading back the framebuffer is genuinely useful (screenshots,
                // read-modify-write), and on a non-direct backend the staging
                // buffer is still the last thing written.
                var surface = self._display.begin_frame() catch return -1;
                if (self._offset >= surface.pixels.len) return 0;
                const count = @min(buffer.len, surface.pixels.len - self._offset);
                @memcpy(buffer[0..count], surface.pixels[self._offset .. self._offset + count]);
                self._offset += count;
                return @intCast(count);
            }

            pub fn write(self: *Self, buffer: []const u8) isize {
                var surface = self._display.begin_frame() catch return -1;
                if (self._offset >= surface.pixels.len) return 0;
                const count = @min(buffer.len, surface.pixels.len - self._offset);
                @memcpy(surface.pixels[self._offset .. self._offset + count], buffer[0..count]);
                self._offset += count;

                const m = self._display.mode().?;
                self._display.commit(.{ .x = 0, .y = 0, .width = m.width, .height = m.height });

                // A write that fills the frame presents it and rewinds, so
                // `cat frame.raw > /dev/fb0` in a loop animates without ioctls.
                if (self._offset >= surface.pixels.len) {
                    self._display.present();
                    self._offset = 0;
                }
                return @intCast(count);
            }

            pub fn seek(self: *Self, offset: i64, base: i32) anyerror!i64 {
                const end: i64 = @intCast(self.frame_size());
                const target: i64 = switch (base) {
                    0 => offset,
                    1 => @as(i64, @intCast(self._offset)) + offset,
                    2 => end + offset,
                    else => return kernel.errno.ErrnoSet.InvalidArgument,
                };
                if (target < 0 or target > end) return kernel.errno.ErrnoSet.InvalidArgument;
                self._offset = @intCast(target);
                return target;
            }

            pub fn sync(self: *Self) i32 {
                // fsync(fd) presents whatever has been written so far — the
                // explicit flush for callers that draw partial frames.
                self._display.present();
                self._offset = 0;
                return 0;
            }

            pub fn tell(self: *Self) i64 {
                return @intCast(self._offset);
            }

            pub fn name(self: *const Self) []const u8 {
                return self._name;
            }

            pub fn ioctl(self: *Self, op: i32, maybe_arg: ?*anyopaque) i32 {
                switch (op) {
                    YASFB_PRESENT => {
                        self._display.present();
                        self._offset = 0;
                        return 0;
                    },
                    YASFB_GET_INFO => {
                        const arg = maybe_arg orelse return -1;
                        const info: *Info = @ptrCast(@alignCast(arg));
                        const m = self._display.mode() orelse return -1;
                        const caps = self._display.caps();
                        info.* = .{
                            .width = m.width,
                            .height = m.height,
                            .stride = m.width * m.format.bytes_per_pixel(),
                            .bits_per_pixel = m.format.bytes_per_pixel() * 8,
                            .format = @intFromEnum(m.format),
                            .buffer_count = caps.buffer_count,
                        };
                        return 0;
                    },
                    YASFB_SET_MODE => {
                        const arg = maybe_arg orelse return -1;
                        const request: *const ModeRequest = @ptrCast(@alignCast(arg));
                        const format = std.meta.intToEnum(hal.display.PixelFormat, request.format) catch return -1;
                        self._display.set_mode(.{
                            .width = request.width,
                            .height = request.height,
                            .format = format,
                        }) catch return -1;
                        self._offset = 0;
                        return 0;
                    },
                    YASFB_POLL_EVENT => {
                        const arg = maybe_arg orelse return -1;
                        const event: *hal.display.Event = @ptrCast(@alignCast(arg));
                        if (self._display.poll_event()) |received| {
                            event.* = received;
                            return 1;
                        }
                        event.* = .{};
                        return 0;
                    },
                    else => return -1,
                }
            }

            pub fn fcntl(self: *Self, op: i32, arg: ?*anyopaque) i32 {
                _ = self;
                _ = op;
                _ = arg;
                return 0;
            }

            pub fn size(self: *const Self) u64 {
                return self.frame_size();
            }

            pub fn truncate(self: *Self, length: u64) anyerror!void {
                _ = self;
                _ = length;
                return kernel.errno.ErrnoSet.InvalidArgument;
            }

            pub fn filetype(self: *const Self) FileType {
                _ = self;
                return FileType.CharDevice;
            }
        });
    };
    return Internal.DisplayFileImpl;
}
