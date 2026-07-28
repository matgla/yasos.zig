//
// display_shm.zig
//
// Display backend for QEMU: a framebuffer in a fixed window of guest RAM.
//
// Under a host-mmap'd launch
//   -machine mps2-an505,memory-backend=mem0
//   -object memory-backend-file,id=mem0,size=16M,mem-path=<file>,share=on
// guest RAM at 0x80000000 *is* an mmap of <file>, so the `fbdev` window from
// linker_script.ld sits at a fixed offset in that file (0x00DC0000). The host
// viewer (scripts/fbview.py) mmaps the very same pages and blits them into an
// SDL window.
//
// That is the whole reason this backend exists: it gets an interactive window
// out of QEMU with no device model, no QEMU fork, and — crucially — no MMIO
// trap per pixel. Routing a framebuffer through a modelled UART or MMIO
// register costs a TCG exit per access and would crawl at 640x480; shared pages
// cost nothing because both sides are touching the same physical memory.
//
// This is also not throwaway scaffolding: it is exactly the topology of the
// board that puts the framebuffer in PSRAM and dedicates a core to scanout, so
// the driver above it is the real one.
//
// Layout of the window (host and guest MUST agree — mirrored in fbview.py):
//   0x000000  Header (64 B)
//   0x000040  input ring, 256 x 8 B events, host produces / guest consumes
//   0x001000  buffer 0
//   0x001000 + frame_size  buffer 1 (when double buffered)
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

const display = @import("hal_interface").display;

/// "YFB1" little-endian. The host spins until it sees this, so it is written
/// last (release) once every other header field is valid.
pub const MAGIC: u32 = 0x31424659;
pub const VERSION: u16 = 1;

pub const FLAG_MODE_VALID: u16 = 1 << 0;

pub const INPUT_RING_OFFSET: u32 = 64;
pub const INPUT_RING_CAPACITY: u32 = 256;
pub const FRAME_BASE_OFFSET: u32 = 0x1000;

/// 64 bytes exactly. Field order is ABI — scripts/fbview.py unpacks this.
pub const Header = extern struct {
    magic: u32,
    version: u16,
    flags: u16,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    buffer_count: u32,
    buffer_offset: [2]u32,
    /// Index of the buffer the host should be showing.
    front: u32,
    /// Bumped by the guest on every present(); the host redraws when it moves.
    frame_seq: u32,
    /// Bumped by the host after each redraw — lets the guest tell whether a
    /// viewer is actually attached.
    host_seq: u32,
    /// Ring indices. Host writes head, guest writes tail; both are free-running
    /// and taken modulo capacity.
    input_head: u32,
    input_tail: u32,
    input_capacity: u32,
    input_offset: u32,
};

comptime {
    if (@sizeOf(Header) != 64) @compileError("Header must stay 64 bytes: it is ABI with scripts/fbview.py");
    if (@sizeOf(display.Event) != 8) @compileError("Event must stay 8 bytes: it is ABI with scripts/fbview.py");
}

const supported_modes = [_]display.Mode{
    .{ .width = 640, .height = 480, .format = .rgb332 },
    .{ .width = 320, .height = 240, .format = .rgb332 },
};

pub fn SharedMemoryDisplay(comptime base_address: usize, comptime window_size: usize) type {
    return struct {
        const Self = @This();

        _mode: ?display.Mode = null,
        _buffer_count: u32 = 0,
        _back: u32 = 0,

        pub fn create() Self {
            return .{};
        }

        fn header() *Header {
            return @ptrFromInt(base_address);
        }

        fn window() []u8 {
            const ptr: [*]u8 = @ptrFromInt(base_address);
            return ptr[0..window_size];
        }

        pub fn init(self: *Self) !void {
            self._mode = null;
            self._buffer_count = 0;
            self._back = 0;
            // Invalidate first: on a plain-RAM launch the window is garbage and
            // a stale magic would make a viewer parse nonsense.
            @atomicStore(u32, &header().magic, 0, .release);
            header().* = std.mem.zeroes(Header);
        }

        pub fn caps(self: *const Self) display.Caps {
            return .{
                .direct_access = true,
                .buffer_count = if (self._buffer_count == 0) 2 else self._buffer_count,
                .modes = &supported_modes,
            };
        }

        pub fn mode(self: *const Self) ?display.Mode {
            return self._mode;
        }

        pub fn set_mode(self: *Self, requested: display.Mode) display.Error!void {
            var supported = false;
            for (supported_modes) |m| {
                if (m.width == requested.width and m.height == requested.height and m.format == requested.format) {
                    supported = true;
                    break;
                }
            }
            if (!supported) return display.Error.UnsupportedMode;

            const bpp = requested.format.bytes_per_pixel();
            const stride = requested.width * bpp;
            const frame_size = stride * requested.height;

            // Prefer double buffering; fall back to a single buffer if the mode
            // is too big for the window rather than refusing the mode outright.
            var buffer_count: u32 = 2;
            if (FRAME_BASE_OFFSET + 2 * frame_size > window_size) buffer_count = 1;
            if (FRAME_BASE_OFFSET + frame_size > window_size) return display.Error.UnsupportedMode;

            const hdr = header();
            @atomicStore(u32, &hdr.magic, 0, .release);

            hdr.version = VERSION;
            hdr.flags = FLAG_MODE_VALID;
            hdr.width = requested.width;
            hdr.height = requested.height;
            hdr.stride = stride;
            hdr.format = @intFromEnum(requested.format);
            hdr.buffer_count = buffer_count;
            hdr.buffer_offset[0] = FRAME_BASE_OFFSET;
            hdr.buffer_offset[1] = FRAME_BASE_OFFSET + if (buffer_count > 1) frame_size else 0;
            hdr.front = 0;
            hdr.frame_seq = 0;
            hdr.host_seq = 0;
            hdr.input_head = 0;
            hdr.input_tail = 0;
            hdr.input_capacity = INPUT_RING_CAPACITY;
            hdr.input_offset = INPUT_RING_OFFSET;

            // The window is uninitialised RAM on a plain launch — clear every
            // buffer so the first frame is not noise.
            const mem = window();
            var i: u32 = 0;
            while (i < buffer_count) : (i += 1) {
                const start = hdr.buffer_offset[i];
                @memset(mem[start .. start + frame_size], 0);
            }

            self._mode = requested;
            self._buffer_count = buffer_count;
            self._back = if (buffer_count > 1) 1 else 0;

            // Everything above is visible before the host can observe MAGIC.
            @atomicStore(u32, &hdr.magic, MAGIC, .release);
        }

        pub fn begin_frame(self: *Self) display.Error!display.Surface {
            const m = self._mode orelse return display.Error.NotInitialized;
            const hdr = header();
            const start = hdr.buffer_offset[self._back];
            const frame_size = hdr.stride * m.height;
            return .{
                .pixels = window()[start .. start + frame_size],
                .stride = hdr.stride,
                .width = m.width,
                .height = m.height,
                .format = m.format,
            };
        }

        pub fn commit(self: *Self, rect: display.Rect) void {
            // Direct-access backend: the host reads these pages itself, so
            // there is nothing to push. present() does the publishing.
            _ = self;
            _ = rect;
        }

        pub fn present(self: *Self) void {
            if (self._mode == null) return;
            const hdr = header();
            if (self._buffer_count > 1) {
                const new_front = self._back;
                self._back = 1 - self._back;
                @atomicStore(u32, &hdr.front, new_front, .release);
            }
            // Release: the host must never see the bumped sequence number
            // before the pixels that belong to it.
            @atomicStore(u32, &hdr.frame_seq, hdr.frame_seq +% 1, .release);
        }

        pub fn poll_event(self: *Self) ?display.Event {
            if (self._mode == null) return null;
            const hdr = header();
            const head = @atomicLoad(u32, &hdr.input_head, .acquire);
            const tail = hdr.input_tail;
            if (head == tail) return null;

            const slot = tail % INPUT_RING_CAPACITY;
            const offset = INPUT_RING_OFFSET + slot * @sizeOf(display.Event);
            const events: [*]display.Event = @ptrFromInt(base_address + offset);
            const event = events[0];

            @atomicStore(u32, &hdr.input_tail, tail +% 1, .release);
            return event;
        }
    };
}
