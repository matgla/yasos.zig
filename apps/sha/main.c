/**
 * main.c
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation, either version
 * 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be
 * useful, but WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General
 * Public License along with this program. If not, see
 * <https://www.gnu.org/licenses/>.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>

// SHA256 constants
static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

// Initial hash values
static const uint32_t H0[8] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
};

typedef struct {
    uint32_t state[8];
    uint8_t buffer[64];
    uint64_t bitlen;
    uint32_t buflen;
    uint64_t chunk_count;
} SHA256_CTX;

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x) (ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define EP1(x) (ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#define SIG0(x) (ROTR(x, 7) ^ ROTR(x, 18) ^ ((x) >> 3))
#define SIG1(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))

void sha256_init(SHA256_CTX *ctx) {
    for (int i = 0; i < 8; i++) {
        ctx->state[i] = H0[i];
    }
    ctx->bitlen = 0;
    ctx->buflen = 0;
    ctx->chunk_count = 0;
}

void sha256_print_state(SHA256_CTX *ctx, uint64_t chunk_num) {
    printf("Chunk %llu hash: ", (unsigned long long)chunk_num);
    for (int i = 0; i < 8; i++) {
        printf("%08x", ctx->state[i]);
    }
    printf("\n");
}

void sha256_transform(SHA256_CTX *ctx, const uint8_t data[]) {
    uint32_t a, b, c, d, e, f, g, h, t1, t2, m[64];
    int i, j;

    // Prepare message schedule
    for (i = 0, j = 0; i < 16; ++i, j += 4) {
        m[i] = (data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | (data[j + 3]);
    }
    for (; i < 64; ++i) {
        m[i] = SIG1(m[i - 2]) + m[i - 7] + SIG0(m[i - 15]) + m[i - 16];
    }

    // Initialize working variables
    a = ctx->state[0];
    b = ctx->state[1];
    c = ctx->state[2];
    d = ctx->state[3];
    e = ctx->state[4];
    f = ctx->state[5];
    g = ctx->state[6];
    h = ctx->state[7];

    // Main loop
    for (i = 0; i < 64; ++i) {
        t1 = h + EP1(e) + CH(e, f, g) + K[i] + m[i];
        t2 = EP0(a) + MAJ(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    // Add compressed chunk to current hash value
    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
    ctx->state[4] += e;
    ctx->state[5] += f;
    ctx->state[6] += g;
    ctx->state[7] += h;

    ctx->chunk_count++;
    // sha256_print_state(ctx, ctx->chunk_count);
}

void sha256_update(SHA256_CTX *ctx, const uint8_t *data, size_t len) {
    uint32_t i;

    for (i = 0; i < len; ++i) {
        ctx->buffer[ctx->buflen] = data[i];
        ctx->buflen++;
        if (ctx->buflen == 64) {
            sha256_transform(ctx, ctx->buffer);
            ctx->bitlen += 512;
            ctx->buflen = 0;
        }
    }
}

void sha256_final(SHA256_CTX *ctx, uint8_t hash[]) {
    uint32_t i;

    i = ctx->buflen;

    // Pad whatever data is left in the buffer
    if (ctx->buflen < 56) {
        ctx->buffer[i++] = 0x80;
        while (i < 56) {
            ctx->buffer[i++] = 0x00;
        }
    } else {
        ctx->buffer[i++] = 0x80;
        while (i < 64) {
            ctx->buffer[i++] = 0x00;
        }
        sha256_transform(ctx, ctx->buffer);
        memset(ctx->buffer, 0, 56);
    }

    // Append total message length in bits
    ctx->bitlen += ctx->buflen * 8;
    ctx->buffer[63] = ctx->bitlen;
    ctx->buffer[62] = ctx->bitlen >> 8;
    ctx->buffer[61] = ctx->bitlen >> 16;
    ctx->buffer[60] = ctx->bitlen >> 24;
    ctx->buffer[59] = ctx->bitlen >> 32;
    ctx->buffer[58] = ctx->bitlen >> 40;
    ctx->buffer[57] = ctx->bitlen >> 48;
    ctx->buffer[56] = ctx->bitlen >> 56;
    sha256_transform(ctx, ctx->buffer);

    // Produce final hash value
    for (i = 0; i < 4; ++i) {
        hash[i]      = (ctx->state[0] >> (24 - i * 8)) & 0xff;
        hash[i + 4]  = (ctx->state[1] >> (24 - i * 8)) & 0xff;
        hash[i + 8]  = (ctx->state[2] >> (24 - i * 8)) & 0xff;
        hash[i + 12] = (ctx->state[3] >> (24 - i * 8)) & 0xff;
        hash[i + 16] = (ctx->state[4] >> (24 - i * 8)) & 0xff;
        hash[i + 20] = (ctx->state[5] >> (24 - i * 8)) & 0xff;
        hash[i + 24] = (ctx->state[6] >> (24 - i * 8)) & 0xff;
        hash[i + 28] = (ctx->state[7] >> (24 - i * 8)) & 0xff;
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <file>\n", argv[0]);
        return 1;
    }

    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    SHA256_CTX ctx;
    uint8_t buffer[4096];
    uint8_t hash[32];
    ssize_t bytes_read;

    sha256_init(&ctx);

    while ((bytes_read = read(fd, buffer, sizeof(buffer))) > 0) {
        sha256_update(&ctx, buffer, bytes_read);
    }

    if (bytes_read < 0) {
        perror("read");
        close(fd);
        return 1;
    }

    sha256_final(&ctx, hash);

    for (int i = 0; i < 32; i++) {
        printf("%02x", hash[i]);
    }
    printf("\n");

    close(fd);
    return 0;
}

