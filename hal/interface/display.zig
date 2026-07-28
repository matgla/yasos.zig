//
// display.zig
//
// Placement-agnostic display interface.
//
// The whole point of this interface is that callers NEVER learn where the
// framebuffer physically lives. Three very different topologies have to hide
// behind it:
//
//   - framebuffer on an extension board, reachable only over the link: the
//     driver hands out a staging buffer and `commit()` pushes the dirty rect
//     across the wire;
//   - framebuffer in PSRAM with a second core scanning it out: `begin_frame()`
//     returns the real memory and `commit()` is nearly free;
//   - framebuffer in a host-mmap'd RAM window under QEMU (see
//     hal/source/arm/qemu_mps2/source/display_shm.zig): same as above, with the
//     host renderer playing the part of the scanout hardware.
//
// So the contract is begin_frame() -> commit(rect) -> present(), and
// `caps().direct_access` only ever tells a caller whether it MAY take a fast
// path — never that it may assume one. A caller that ignores caps() entirely
// must still render correctly on every backend.
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

/// Pixel formats. Values are ABI — they are written into the shared header that
/// the host viewer parses, so never renumber an existing entry.
pub const PixelFormat = enum(u32) {
    /// 8 bits per pixel, 3-3-2 direct colour (RRRGGGBB) — what the VGA and DVI
    /// extension boards take on the wire.
    rgb332 = 1,

    pub fn bytes_per_pixel(self: PixelFormat) u32 {
        return switch (self) {
            .rgb332 => 1,
        };
    }
};

pub const Mode = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
};

pub const Caps = struct {
    /// True when begin_frame() hands back memory the scanout side reads
    /// directly, so commit() is a no-op and in-place rendering is cheap. Callers
    /// may use this to skip a staging copy; they may NOT assume it.
    direct_access: bool,
    /// Number of buffers the backend rotates through. 1 = render straight to
    /// the visible buffer (expect tearing), 2 = double buffered.
    buffer_count: u32,
    modes: []const Mode,
};

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// A frame the caller may draw into. `pixels` is only valid between
/// begin_frame() and present().
pub const Surface = struct {
    pixels: []u8,
    stride: u32,
    width: u32,
    height: u32,
    format: PixelFormat,

    pub fn row(self: Surface, y: u32) []u8 {
        const start = y * self.stride;
        return self.pixels[start .. start + self.stride];
    }
};

pub const EventType = enum(u8) {
    none = 0,
    key_down = 1,
    key_up = 2,
    mouse_move = 3,
    mouse_button_down = 4,
    mouse_button_up = 5,
};

/// Input coming back from whatever is displaying the framebuffer. On the
/// extension boards this will be the board's own PS/2 or USB input; under QEMU
/// it is the host viewer window. 8 bytes, ABI-shared with scripts/fbview.py.
pub const Event = extern struct {
    type: u8 = 0,
    flags: u8 = 0,
    /// ASCII for printable keys, or a KEY_* code below.
    code: u16 = 0,
    x: i16 = 0,
    y: i16 = 0,
};

// Non-ASCII keys. Deliberately above the ASCII range so `code` can just be
// tested directly for ordinary characters.
pub const KEY_ESCAPE: u16 = 0x100;
pub const KEY_UP: u16 = 0x101;
pub const KEY_DOWN: u16 = 0x102;
pub const KEY_LEFT: u16 = 0x103;
pub const KEY_RIGHT: u16 = 0x104;

pub const Error = error{
    UnsupportedMode,
    NotInitialized,
};

pub fn Display(comptime DisplayImpl: anytype) type {
    return struct {
        impl: DisplayImpl,

        const Self = @This();

        pub fn create() Self {
            return .{ .impl = DisplayImpl.create() };
        }

        /// Bring the panel up far enough to answer caps(). Does not select a
        /// mode — nothing is displayed until set_mode() succeeds.
        pub fn init(self: *Self) !void {
            return self.impl.init();
        }

        pub fn caps(self: *const Self) Caps {
            return self.impl.caps();
        }

        /// Currently selected mode, or null when set_mode() has not run yet.
        pub fn mode(self: *const Self) ?Mode {
            return self.impl.mode();
        }

        pub fn set_mode(self: *Self, requested: Mode) Error!void {
            return self.impl.set_mode(requested);
        }

        /// Acquire the buffer for the next frame. Contents are undefined —
        /// with buffer_count > 1 this is the frame before last, not the frame
        /// currently on screen.
        pub fn begin_frame(self: *Self) Error!Surface {
            return self.impl.begin_frame();
        }

        /// Publish `rect` of the current frame. Free on direct-access backends;
        /// a DMA push over the link otherwise. Safe to call repeatedly.
        pub fn commit(self: *Self, rect: Rect) void {
            self.impl.commit(rect);
        }

        /// Make the frame started by begin_frame() the visible one.
        pub fn present(self: *Self) void {
            self.impl.present();
        }

        /// Pop one input event, or null when the queue is empty. Never blocks.
        pub fn poll_event(self: *Self) ?Event {
            return self.impl.poll_event();
        }
    };
}
