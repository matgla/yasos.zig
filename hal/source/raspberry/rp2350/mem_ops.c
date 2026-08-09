/*
 * mem_ops.c — word-at-a-time memcpy/memset/memmove for the kernel.
 *
 * The build links newlib-nano (-lc_nano, with -fno-compiler-rt), whose
 * size-optimised copy moves one byte per iteration:
 *
 *     memcpy:  ldrb.w r4, [r1], #1 ; strb.w r4, [r3, #1]! ; bne
 *
 * 943 call sites reach it through __aeabi_memcpy, so every copy the kernel
 * makes — process images out of the loader, VFS reads, FatFs cache lines, the
 * SDIO bounce buffer — ran four bytes-worth of loop per word. It is worst
 * against PSRAM, where a byte store is a QMI transaction rather than part of a
 * cache-line fill. It surfaced as a floor on the SD read path: ~48 us per
 * sector that would not shrink however many blocks went out per DMA, because
 * the floor was this loop and not the bus.
 *
 * __aeabi_memset was already word-based with a 16-byte unrolled body, which is
 * why the page-clear path never showed the problem and why its measured
 * 55 MB/s against PSRAM is a real bus figure. Only the copy side was left
 * behind; the memset here replaces the byte-loop memset sitting beside it.
 *

 * Two build details this file depends on, both in the RP2350 HAL build.zig:
 *
 *   - it is attached to the *kernel* module, not the root one. Link order
 *     matters: an object added to the root module lands ahead of the board
 *     module's malloc_lock.c, which the HAL build requires to come first, and
 *     newlib's conflicting mlock.o gets dragged in behind it.
 *   - -ffreestanding -fno-builtin, so the compiler does not recognise the loops
 *     below and lower them back into calls to the very functions being defined.
 *
 * Copyright (c) 2026 Mateusz Stadnik
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#include <stddef.h>
#include <stdint.h>

/* Below this there is nothing for the alignment prologue to amortise against,
 * so the byte loop is simply the cheaper answer. */
#define WORD_PATH_MIN 16u

/* The copy itself. Exposed through the __aeabi_memcpy* entry points below
 * rather than as `memcpy`: the linker gets `memcpy` out of libc_nano.a before
 * any object of ours is parsed, so defining that name is a duplicate-symbol
 * error no matter where the object sits in the link. __aeabi_memcpy is what the
 * compiler actually emits — all 943 kernel call sites go through it — so
 * overriding there captures the traffic and leaves newlib's byte loop serving
 * only the two literal `memcpy` calls in the tree. */
static void *copy_forward(void *restrict dst, const void *restrict src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;

    /* A word path needs both sides to reach 4-byte alignment together, which
     * they can only do if they start equally misaligned. The test is on
     * agreement rather than on either address alone. */
    if (n >= WORD_PATH_MIN && ((((uintptr_t)d) ^ ((uintptr_t)s)) & 3u) == 0u) {
        while (((uintptr_t)d & 3u) != 0u) {
            *d++ = *s++;
            --n;
        }

        uint32_t *dw = (uint32_t *)(void *)d;
        const uint32_t *sw = (const uint32_t *)(const void *)s;

        /* Four words per iteration: enough for the compiler to issue a
         * load-multiple/store-multiple pair, which is also what lets the QMI
         * write buffer turn a PSRAM destination into bursts instead of single
         * word transactions. */
        while (n >= 16u) {
            uint32_t w0 = sw[0];
            uint32_t w1 = sw[1];
            uint32_t w2 = sw[2];
            uint32_t w3 = sw[3];
            dw[0] = w0;
            dw[1] = w1;
            dw[2] = w2;
            dw[3] = w3;
            dw += 4;
            sw += 4;
            n -= 16u;
        }
        while (n >= 4u) {
            *dw++ = *sw++;
            n -= 4u;
        }

        d = (unsigned char *)(void *)dw;
        s = (const unsigned char *)(const void *)sw;
    }

    while (n-- != 0u) {
        *d++ = *s++;
    }
    return dst;
}

/* The three ARM EABI copy entry points. The 4/8 variants promise the compiler
 * has proved both sides aligned to that width; copy_forward re-derives it
 * cheaply, so they share one body rather than duplicating the loop. */
void __aeabi_memcpy(void *dst, const void *src, size_t n)
{
    copy_forward(dst, src, n);
}

void __aeabi_memcpy4(void *dst, const void *src, size_t n)
{
    copy_forward(dst, src, n);
}

void __aeabi_memcpy8(void *dst, const void *src, size_t n)
{
    copy_forward(dst, src, n);
}

void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    unsigned char b = (unsigned char)c;

    if (n >= WORD_PATH_MIN) {
        uint32_t w = (uint32_t)b;
        w |= w << 8;
        w |= w << 16;

        while (((uintptr_t)d & 3u) != 0u) {
            *d++ = b;
            --n;
        }

        uint32_t *dw = (uint32_t *)(void *)d;
        while (n >= 16u) {
            dw[0] = w;
            dw[1] = w;
            dw[2] = w;
            dw[3] = w;
            dw += 4;
            n -= 16u;
        }
        while (n >= 4u) {
            *dw++ = w;
            n -= 4u;
        }
        d = (unsigned char *)(void *)dw;
    }

    while (n-- != 0u) {
        *d++ = b;
    }
    return dst;
}

/* Overlap-safe copy. Forward-copies whenever the regions cannot overlap in a
 * way that matters, so the common non-overlapping call gets the word path above
 * rather than a byte loop of its own. */
void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;

    if (d == s || n == 0u) {
        return dst;
    }

    if (d < s || d >= s + n) {
        return copy_forward(dst, src, n);
    }

    /* Overlapping with the destination inside the source: copy backwards. Word
     * stepping needs the same shared alignment, measured at the tail since that
     * is where a backward copy starts. */
    d += n;
    s += n;
    if (n >= WORD_PATH_MIN && ((((uintptr_t)d) ^ ((uintptr_t)s)) & 3u) == 0u) {
        while (((uintptr_t)d & 3u) != 0u) {
            *--d = *--s;
            --n;
        }
        uint32_t *dw = (uint32_t *)(void *)d;
        const uint32_t *sw = (const uint32_t *)(const void *)s;
        while (n >= 4u) {
            *--dw = *--sw;
            n -= 4u;
        }
        d = (unsigned char *)(void *)dw;
        s = (const unsigned char *)(const void *)sw;
    }

    while (n-- != 0u) {
        *--d = *--s;
    }
    return dst;
}
