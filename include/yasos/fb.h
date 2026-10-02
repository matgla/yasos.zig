/*
 * yasos/fb.h — userspace interface to /dev/fb0.
 *
 * Mirrors source/kernel/drivers/display/display_file.zig and
 * hal/interface/display.zig. Installed into rootfs/usr/include/yasos/fb.h by
 * build_rootfs.sh.
 *
 * The device deliberately says nothing about where the framebuffer physically
 * lives — it may be RAM shared with a host viewer under QEMU, PSRAM scanned out
 * by a second core, or memory on an extension board reachable only over the
 * link. Write a frame, present it, poll for input; that works everywhere.
 *
 *   int fd = open("/dev/fb0", O_RDWR);
 *   struct yasfb_mode mode = { 640, 480, YASFB_FMT_RGB332 };
 *   ioctl(fd, YASFB_SET_MODE, &mode);
 *
 *   struct yasfb_info info;
 *   ioctl(fd, YASFB_GET_INFO, &info);
 *
 *   write(fd, pixels, info.stride * info.height);   // a full frame presents
 *
 *   struct yasfb_event ev;
 *   while (ioctl(fd, YASFB_POLL_EVENT, &ev) == 1) { ... }
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 */

#ifndef YASOS_FB_H
#define YASOS_FB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * ioctl opcodes.
 *
 * Magic 0x59 ('Y' for yasos). This is deliberately NOT Linux's fbdev range
 * 0x46xx ('F'): /dev/fb0 here is not a Linux framebuffer and the structs below
 * are not Linux's. Reusing its opcodes would mean a ported program calling
 * FBIOGET_VSCREENINFO (0x4600) silently got 24 bytes of struct yasfb_info
 * written into its 160-byte struct fb_var_screeninfo with a 0 return. On a
 * private magic that call simply fails with -1 instead.
 *
 * (POSIX specifies nothing at all about framebuffers, so there is no standard
 * to follow here -- Linux fbdev, Linux DRM/KMS, FreeBSD fbio, BSD wsdisplay,
 * Zephyr and NuttX are all mutually incompatible. This is one more.)
 */
#define YASFB_GET_INFO 0x5900
#define YASFB_SET_MODE 0x5901
/* Publish whatever has been written since the last present. A write that fills
   the frame presents on its own, so this is only needed for partial updates. */
#define YASFB_PRESENT 0x5902
/* Returns 1 and fills the event when one was queued, 0 when the queue is
   empty. Never blocks. */
#define YASFB_POLL_EVENT 0x5903

/* Pixel formats. 8bpp 3-3-2 direct colour is what the VGA and DVI extension
   boards take on the wire. */
#define YASFB_FMT_RGB332 1

struct yasfb_info {
  uint32_t width;
  uint32_t height;
  uint32_t stride; /* bytes per row */
  uint32_t bits_per_pixel;
  uint32_t format;
  uint32_t buffer_count; /* 2 = double buffered, 1 = expect tearing */
};

struct yasfb_mode {
  uint32_t width;
  uint32_t height;
  uint32_t format;
};

/* Event types */
#define YASFB_EV_NONE 0
#define YASFB_EV_KEY_DOWN 1
#define YASFB_EV_KEY_UP 2
#define YASFB_EV_MOUSE_MOVE 3
#define YASFB_EV_MOUSE_BUTTON_DOWN 4
#define YASFB_EV_MOUSE_BUTTON_UP 5

/* Key codes. Printable keys arrive as their ASCII value, so `ev.code == 'q'`
   works directly; these cover the rest. */
#define YASFB_KEY_ESCAPE 0x100
#define YASFB_KEY_UP 0x101
#define YASFB_KEY_DOWN 0x102
#define YASFB_KEY_LEFT 0x103
#define YASFB_KEY_RIGHT 0x104

struct yasfb_event {
  uint8_t type;
  uint8_t flags; /* mouse button index for button events */
  uint16_t code;
  int16_t x;
  int16_t y;
};

/* Pack an 8-bit RGB332 pixel. r/g/b are 0-255 and get truncated to the 3-3-2
   layout the hardware DAC expects. */
static inline uint8_t yasfb_rgb(uint8_t r, uint8_t g, uint8_t b) {
  return (uint8_t)(((r & 0xE0)) | ((g & 0xE0) >> 3) | ((b & 0xC0) >> 6));
}

#ifdef __cplusplus
}
#endif

#endif /* YASOS_FB_H */
