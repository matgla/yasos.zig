/*
 * fbdemo — interactive test app for /dev/fb0.
 *
 * Draws a colour-field background plus a box you can move with the arrow keys
 * or the mouse, so both directions of the framebuffer path are visible at once:
 * pixels out to the display, input back from it.
 *
 * Under QEMU the "display" is scripts/fbview.py rendering the shared memory
 * window; on hardware it will be the VGA or DVI extension board. This app does
 * not know which, and that is the point.
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <yasos/fb.h>

static unsigned char *frame;
static struct yasfb_info info;

static void fill_rect(int x, int y, int w, int h, unsigned char color) {
  int yy, xx;
  for (yy = y; yy < y + h; ++yy) {
    if (yy < 0 || yy >= (int)info.height)
      continue;
    for (xx = x; xx < x + w; ++xx) {
      if (xx < 0 || xx >= (int)info.width)
        continue;
      frame[yy * info.stride + xx] = color;
    }
  }
}

static void draw_background(void) {
  unsigned int y, x;
  for (y = 0; y < info.height; ++y) {
    for (x = 0; x < info.width; ++x) {
      /* A smooth red/green ramp with a blue checker so it is obvious when the
         stride or the pixel format is wrong. */
      unsigned char r = (unsigned char)(x * 255 / info.width);
      unsigned char g = (unsigned char)(y * 255 / info.height);
      unsigned char b = ((x >> 4) ^ (y >> 4)) & 1 ? 0xC0 : 0x00;
      frame[y * info.stride + x] = yasfb_rgb(r, g, b);
    }
  }
}

int main(void) {
  int fd, running = 1, first = 1;
  int box_x, box_y;
  const int box_size = 48;
  struct yasfb_mode mode;
  struct yasfb_event ev;

  fd = open("/dev/fb0", O_RDWR);
  if (fd < 0) {
    fprintf(stderr, "fbdemo: cannot open /dev/fb0\n");
    return 1;
  }

  mode.width = 640;
  mode.height = 480;
  mode.format = YASFB_FMT_RGB332;
  if (ioctl(fd, YASFB_SET_MODE, &mode) != 0) {
    fprintf(stderr, "fbdemo: cannot set 640x480 rgb332\n");
    close(fd);
    return 1;
  }

  if (ioctl(fd, YASFB_GET_INFO, &info) != 0) {
    fprintf(stderr, "fbdemo: cannot query mode\n");
    close(fd);
    return 1;
  }

  printf("fbdemo: %ux%u, %u bpp, stride %u, %u buffer(s)\n", info.width,
         info.height, info.bits_per_pixel, info.stride, info.buffer_count);
  printf("arrows or mouse move the box, 'q' or ESC quits\n");

  frame = malloc(info.stride * info.height);
  if (!frame) {
    fprintf(stderr, "fbdemo: out of memory\n");
    close(fd);
    return 1;
  }

  box_x = (int)info.width / 2 - box_size / 2;
  box_y = (int)info.height / 2 - box_size / 2;

  while (running) {
    /* First pass always draws; after that only when something moved. */
    int dirty = first;
    struct timespec idle;
    first = 0;

    while (ioctl(fd, YASFB_POLL_EVENT, &ev) == 1) {
      if (ev.type == YASFB_EV_KEY_DOWN) {
        switch (ev.code) {
        case YASFB_KEY_LEFT:  box_x -= 8; dirty = 1; break;
        case YASFB_KEY_RIGHT: box_x += 8; dirty = 1; break;
        case YASFB_KEY_UP:    box_y -= 8; dirty = 1; break;
        case YASFB_KEY_DOWN:  box_y += 8; dirty = 1; break;
        case YASFB_KEY_ESCAPE:
        case 'q':
          running = 0;
          break;
        default:
          break;
        }
      } else if (ev.type == YASFB_EV_MOUSE_MOVE) {
        box_x = ev.x - box_size / 2;
        box_y = ev.y - box_size / 2;
        dirty = 1;
      }
    }

    if (dirty) {
      draw_background();
      /* White border, so the box is visible against any part of the ramp. */
      fill_rect(box_x - 2, box_y - 2, box_size + 4, box_size + 4, 0xFF);
      fill_rect(box_x, box_y, box_size, box_size, yasfb_rgb(0x00, 0x40, 0xFF));

      lseek(fd, 0, SEEK_SET);
      write(fd, frame, info.stride * info.height);
    }

    /* Input is polled, not blocking, so pace the loop rather than spinning a
       core flat out — that would starve everything else under QEMU. */
    idle.tv_sec = 0;
    idle.tv_nsec = 16 * 1000 * 1000;
    nanosleep(&idle, NULL);
  }

  printf("fbdemo: bye\n");
  free(frame);
  close(fd);
  return 0;
}
