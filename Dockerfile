FROM ubuntu:24.04

ARG TARGETPLATFORM
ARG ZIG_VERSION="0.15.0-dev.828+3ce8d19f7"
ARG ARM_NONE_EABI_GCC_VERSION="14.2.rel1"

ENV PATH="/opt/zig:/opt/arm-none-eabi-gcc/bin:$PATH"

RUN apt-get update -y
RUN apt-get install -y make cmake
RUN apt-get install -y python3 python3-pip python3-venv
RUN apt-get install -y wget 
RUN apt-get install -y git

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
