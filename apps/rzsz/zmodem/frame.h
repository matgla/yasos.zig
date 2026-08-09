/*
 Copyright (c) 2025 Mateusz Stadnik

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#pragma once

#include <stdint.h>

/* Frame encoding types */
typedef enum {
    ZBIN = 'A',
    ZHEX = 'B',
    ZBIN32 = 'C',
} ZFrameEncoding;

/* Frame types */
typedef enum {
    ZRQINIT = 0x00,
    ZRINIT  = 0x01,
    ZSINIT  = 0x02,
    ZACK    = 0x03,
    ZFILE   = 0x04,
    ZSKIP   = 0x05,
    ZNAK    = 0x06,
    ZABORT  = 0x07,
    ZFIN    = 0x08,
    ZRPOS   = 0x09,
    ZDATA   = 0x0a,
    ZEOF    = 0x0b,
    ZFERR   = 0x0c,
    ZCRC    = 0x0d,
    ZFREECNT = 0x11,
} ZFrameType;

/* Protocol constants */
#define ZPAD  '*'   /* 0x2a - pad character starts every frame */
#define ZDLE  0x18  /* ZDLE escape character */

/* Data sub-packet terminators */
#define ZCRCE  'h'  /* 0x68 - CRC next, end, more follows */
#define ZCRCG  'i'  /* 0x69 - CRC next, no ZACK */
#define ZCRCQ  'j'  /* 0x6a - CRC next, ZACK requested */
#define ZCRCW  'k'  /* 0x6b - CRC next, ZACK requested, end of frame */

/* ZRINIT capability flags (f2 byte) */
#define CANFDX  0x01  /* can do full duplex */
#define ESCCTL  0x40  /* escapes all control chars */
