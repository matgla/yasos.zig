#!/usr/bin/env python3
"""Interactive window onto the yasos guest framebuffer running under QEMU.

Under a host-mmap'd RAM launch

    -machine mps2-an505,memory-backend=mem0
    -object memory-backend-file,id=mem0,size=16M,mem-path=<file>,share=on

guest RAM at 0x80000000 *is* an mmap of <file>. The `fbdev` window from
hal/source/arm/qemu_mps2/linker_script.ld therefore sits at a fixed offset in
that file, and this script mmaps the very same pages the guest renders into.

So there is no QEMU device model, no QEMU fork, and no MMIO trap per pixel: the
guest stores to memory, we read that memory, SDL puts it on screen. Keyboard and
mouse go back through a ring buffer in the same window, which the guest pops via
ioctl(fd, YASFB_POLL_EVENT, &ev).

Layout and struct packing are ABI shared with
hal/source/arm/qemu_mps2/source/display_shm.zig — change both together.

Usage:
    scripts/fbview.py /tmp/yasos_ram.bin           # follow a running qemu
    scripts/fbview.py /tmp/yasos_ram.bin --scale 2
"""
import argparse
import mmap
import os
import struct
import sys
import time
from pathlib import Path

# MUST match linker_script.ld `fbdev` + qemu_mps2_an505.zig fbdev_address/size.
RAM_BASE = 0x80000000
FBDEV_ADDR = 0x80DC0000
FBDEV_SIZE = 1024 * 1024
FBDEV_OFFSET = FBDEV_ADDR - RAM_BASE

MAGIC = 0x31424659  # "YFB1"

HEADER_FORMAT = "<IHHIIIIIIIIIIIIII"
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
assert HEADER_SIZE == 64, HEADER_SIZE

# Byte offsets of the fields we poke individually.
OFF_FRAME_SEQ = 40
OFF_HOST_SEQ = 44
OFF_INPUT_HEAD = 48
OFF_INPUT_TAIL = 52

EVENT_FORMAT = "<BBHhh"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
assert EVENT_SIZE == 8, EVENT_SIZE

FMT_RGB332 = 1

EV_KEY_DOWN = 1
EV_KEY_UP = 2
EV_MOUSE_MOVE = 3
EV_MOUSE_BUTTON_DOWN = 4
EV_MOUSE_BUTTON_UP = 5

KEY_ESCAPE = 0x100
KEY_UP = 0x101
KEY_DOWN = 0x102
KEY_LEFT = 0x103
KEY_RIGHT = 0x104


def rgb332_palette():
    """Expand the 8-bit RRRGGGBB hardware format to 256 RGB triples.

    Each field is scaled so an all-ones field reaches 255 exactly (3 bits ->
    x255/7, 2 bits -> x255/3), which is what a resistor-ladder DAC does.
    """
    palette = []
    for value in range(256):
        r = (value >> 5) & 0x7
        g = (value >> 2) & 0x7
        b = value & 0x3
        palette.append((r * 255 // 7, g * 255 // 7, b * 255 // 3))
    return palette


class Header:
    __slots__ = (
        "magic", "version", "flags", "width", "height", "stride", "format",
        "buffer_count", "buffer_offset", "front", "frame_seq", "host_seq",
        "input_head", "input_tail", "input_capacity", "input_offset",
    )

    def __init__(self, raw):
        fields = struct.unpack(HEADER_FORMAT, raw)
        (self.magic, self.version, self.flags, self.width, self.height,
         self.stride, self.format, self.buffer_count, buf0, buf1, self.front,
         self.frame_seq, self.host_seq, self.input_head, self.input_tail,
         self.input_capacity, self.input_offset) = fields
        self.buffer_offset = (buf0, buf1)

    def valid(self):
        return (
            self.magic == MAGIC
            and 0 < self.width <= 4096
            and 0 < self.height <= 4096
            and self.format == FMT_RGB332
            and 1 <= self.buffer_count <= 2
        )


class SharedFramebuffer:
    def __init__(self, path):
        self.path = path
        size = os.path.getsize(path)
        if size < FBDEV_OFFSET + FBDEV_SIZE:
            raise SystemExit(
                f"{path} is {size} bytes; need at least "
                f"{FBDEV_OFFSET + FBDEV_SIZE} for the fbdev window. "
                "Is this the qemu memory-backend-file (16M)?"
            )
        self.fd = os.open(path, os.O_RDWR)
        self.map = mmap.mmap(self.fd, FBDEV_SIZE, offset=FBDEV_OFFSET,
                             access=mmap.ACCESS_WRITE)

    def header(self):
        return Header(self.map[0:HEADER_SIZE])

    def frame_seq(self):
        return struct.unpack_from("<I", self.map, OFF_FRAME_SEQ)[0]

    def pixels(self, header):
        start = header.buffer_offset[header.front if header.buffer_count > 1 else 0]
        length = header.stride * header.height
        if start + length > FBDEV_SIZE:
            return None
        return self.map[start:start + length]

    def bump_host_seq(self):
        current = struct.unpack_from("<I", self.map, OFF_HOST_SEQ)[0]
        struct.pack_into("<I", self.map, OFF_HOST_SEQ, (current + 1) & 0xFFFFFFFF)

    def push_event(self, header, ev_type, flags=0, code=0, x=0, y=0):
        """Producer side of the input ring. Drops the event when the guest has
        not drained it — an unread queue means the guest is not looking at
        input, and stalling the viewer for that would be worse."""
        head = struct.unpack_from("<I", self.map, OFF_INPUT_HEAD)[0]
        tail = struct.unpack_from("<I", self.map, OFF_INPUT_TAIL)[0]
        capacity = header.input_capacity or 1
        if (head - tail) & 0xFFFFFFFF >= capacity:
            return False
        slot = head % capacity
        offset = header.input_offset + slot * EVENT_SIZE
        struct.pack_into(EVENT_FORMAT, self.map, offset, ev_type, flags, code, x, y)
        struct.pack_into("<I", self.map, OFF_INPUT_HEAD, (head + 1) & 0xFFFFFFFF)
        return True

    def close(self):
        self.map.close()
        os.close(self.fd)


def translate_key(event, pygame):
    """pygame key -> our 16-bit code. ASCII passes through untouched so the
    guest can just compare against a character literal."""
    special = {
        pygame.K_ESCAPE: KEY_ESCAPE,
        pygame.K_UP: KEY_UP,
        pygame.K_DOWN: KEY_DOWN,
        pygame.K_LEFT: KEY_LEFT,
        pygame.K_RIGHT: KEY_RIGHT,
        pygame.K_RETURN: 13,
        pygame.K_BACKSPACE: 8,
        pygame.K_TAB: 9,
        pygame.K_SPACE: 32,
    }
    if event.key in special:
        return special[event.key]
    text = getattr(event, "unicode", "")
    if text and 0 < ord(text[0]) < 128:
        return ord(text[0])
    if 0 < event.key < 128:
        return event.key
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("backing", help="qemu memory-backend-file path")
    parser.add_argument("--scale", type=int, default=2,
                        help="integer upscale factor (default: 2)")
    parser.add_argument("--fps", type=int, default=60,
                        help="viewer refresh cap (default: 60)")
    parser.add_argument("--title", default="yasos framebuffer")
    args = parser.parse_args()

    import pygame

    fb = SharedFramebuffer(args.backing)
    palette = rgb332_palette()

    pygame.init()
    pygame.display.set_caption(args.title)
    clock = pygame.time.Clock()

    # Until the guest sets a mode there is nothing to size the window from.
    window = pygame.display.set_mode((640, 480))
    font = pygame.font.SysFont(None, 22)
    mode_key = None
    last_seq = None
    surface = None
    running = True
    warned = False

    while running:
        header = fb.header()

        if not header.valid():
            if not warned:
                print(f"waiting for guest framebuffer at {args.backing} "
                      f"+0x{FBDEV_OFFSET:06X} ...")
                warned = True
            window.fill((16, 16, 24))
            message = font.render(
                "waiting for the guest to set a video mode...", True, (200, 200, 210))
            window.blit(message, (20, 20))
            pygame.display.flip()
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    running = False
            clock.tick(10)
            continue

        key = (header.width, header.height, args.scale)
        if key != mode_key:
            mode_key = key
            size = (header.width * args.scale, header.height * args.scale)
            window = pygame.display.set_mode(size)
            surface = pygame.Surface((header.width, header.height), 0, 8)
            surface.set_palette(palette)
            last_seq = None
            print(f"mode {header.width}x{header.height} rgb332, "
                  f"{header.buffer_count} buffer(s) -> window {size[0]}x{size[1]}")

        seq = fb.frame_seq()
        if seq != last_seq:
            last_seq = seq
            data = fb.pixels(header)
            if data is not None:
                # Blit the raw 8bpp bytes straight into the palettized surface.
                # Row-by-row because SDL pads each row to a 4-byte pitch, which
                # only coincidentally equals the stride for widths like 640.
                view = surface.get_buffer()
                pitch = surface.get_pitch()
                if pitch == header.stride:
                    view.write(bytes(data))
                else:
                    for y in range(header.height):
                        row = data[y * header.stride:(y + 1) * header.stride]
                        view.write(bytes(row), y * pitch)
                del view
            # scale() keeps the 8-bit format; the blit to the display surface
            # does the palette expansion.
            if args.scale == 1:
                window.blit(surface, (0, 0))
            else:
                window.blit(pygame.transform.scale(surface, window.get_size()), (0, 0))
            pygame.display.flip()
            fb.bump_host_seq()

        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN:
                # Ctrl-Q closes the viewer without touching the guest.
                if event.key == pygame.K_q and (event.mod & pygame.KMOD_CTRL):
                    running = False
                    continue
                fb.push_event(header, EV_KEY_DOWN, code=translate_key(event, pygame))
            elif event.type == pygame.KEYUP:
                fb.push_event(header, EV_KEY_UP, code=translate_key(event, pygame))
            elif event.type == pygame.MOUSEMOTION:
                x, y = event.pos
                fb.push_event(header, EV_MOUSE_MOVE,
                              x=x // args.scale, y=y // args.scale)
            elif event.type in (pygame.MOUSEBUTTONDOWN, pygame.MOUSEBUTTONUP):
                x, y = event.pos
                kind = (EV_MOUSE_BUTTON_DOWN if event.type == pygame.MOUSEBUTTONDOWN
                        else EV_MOUSE_BUTTON_UP)
                fb.push_event(header, kind, flags=event.button,
                              x=x // args.scale, y=y // args.scale)

        clock.tick(args.fps)

    fb.close()
    pygame.quit()


if __name__ == "__main__":
    main()
