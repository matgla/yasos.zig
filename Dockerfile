FROM ubuntu:24.04

ARG TARGETPLATFORM
ARG ZIG_VERSION="0.17.0-dev.1640+2597da025"

ARG ARM_NONE_EABI_GCC_VERSION="15.2.rel1"

ENV PATH="/opt/zig:/opt/arm-none-eabi-gcc/bin:$PATH"

# Pin Zig's global package cache to a baked /opt path. GitHub Actions container
# jobs bind-mount over $HOME=/github/home, which would shadow the default
# ~/.cache/zig. /opt is untouched by those mounts, and this ENV is inherited by
# the CI job, so packages pre-fetched here (see below) survive into CI.
ENV ZIG_GLOBAL_CACHE_DIR="/opt/zig-global-cache"

RUN apt-get update -y
RUN apt-get install -y make cmake
RUN apt-get install -y python3 python3-pip python3-venv
RUN apt-get install -y wget
RUN apt-get install -y gita
RUN apt-get install -y qemu-system-arm

RUN mkdir -p /opt/zig
RUN mkdir -p /opt/arm-none-eabi-gcc

RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
    export ZIG_ARCH="x86_64"; \
    elif [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
    export ZIG_ARCH="aarch64"; \
    else \
    echo "Unknown TARGET_PLATFORM: $TARGETPLATFORM"; \
    exit 1; \
    fi \
    && wget "https://ziglang.org/builds/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -O /opt/zig/zig.tar.xz \
    && wget "https://developer.arm.com/-/media/Files/downloads/gnu/${ARM_NONE_EABI_GCC_VERSION}/binrel/arm-gnu-toolchain-${ARM_NONE_EABI_GCC_VERSION}-${ZIG_ARCH}-arm-none-eabi.tar.xz" -O /opt/arm-none-eabi-gcc/gcc.tar.xz \
    && cd /opt/zig && tar -xf zig.tar.xz --strip-components=1 \
    && cd /opt/arm-none-eabi-gcc && tar -xf gcc.tar.xz --strip-components=1 \
    && rm /opt/zig/zig.tar.xz \
    && rm /opt/arm-none-eabi-gcc/gcc.tar.xz

# Pre-fetch the flaky transitive FatFs source into the baked global cache. The
# zfat dependency pulls https://elm-chan.org/fsw/ff/arc/ff15a.zip, a single
# un-CDN'd host that frequently times out and breaks CI fetches. The package is
# content-addressed, so once it lives in the cache a `zig build` resolves it by
# hash with no network access. Retry to survive a flaky elm-chan during the
# (infrequent) image build, then assert the package landed so we never publish
# an image silently missing it.
#
# Zig 0.17-dev keeps a fetched package as `p/<hash>.tar.gz`; older Zig unpacked
# it into a `p/<hash>/` directory. Accept either, so a cache-layout change does
# not fail the image build with a misleading "the fetch is flaky" symptom.
RUN FATFS_HASH="N-V-__8AAFQITQCnpmdR7PARImvk-cgb-9lZmjKolexSWkUL" \
    && mkdir -p "$ZIG_GLOBAL_CACHE_DIR" \
    && for i in 1 2 3 4 5; do \
         zig fetch "https://elm-chan.org/fsw/ff/arc/ff15a.zip" && break; \
         echo "zig fetch ff15a.zip attempt $i failed; retrying in 15s"; \
         sleep 15; \
       done \
    && { test -f "$ZIG_GLOBAL_CACHE_DIR/p/${FATFS_HASH}.tar.gz" \
         || test -d "$ZIG_GLOBAL_CACHE_DIR/p/${FATFS_HASH}"; } \
    || { echo "FatFs package ${FATFS_HASH} is not in $ZIG_GLOBAL_CACHE_DIR/p after 5 fetch attempts"; \
         ls -la "$ZIG_GLOBAL_CACHE_DIR/p" 2>/dev/null; \
         exit 1; }

COPY tests/smoke/requirements.txt /opt/smoke/requirements.txt
RUN pip3 install --break-system-packages -r /opt/smoke/requirements.txt

RUN apt-get install -y genromfs

RUN apt-get install -y libusb-1.0-0-dev libtool build-essential
RUN apt-get install -y pkg-config
RUN cd /opt && git clone https://github.com/raspberrypi/openocd.git
RUN apt-get install -y libjim-dev
RUN cd /opt/openocd && ./bootstrap && ./configure --disable-werror && make -j$(nproc) && make install
RUN apt-get install -y curl
