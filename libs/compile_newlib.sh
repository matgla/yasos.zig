#!/bin/sh

cd newlib/build_shared
../configure --target=arm-none-eabi \
    --disable-newlib-supplied-syscalls \
    --enable-shared \

