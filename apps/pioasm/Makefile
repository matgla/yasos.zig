# `?=` would keep make's built-in default (cc), so override that one; the
# in-tree cross compiler when armv8m-tcc is not on PATH.
ifeq ($(origin CC),default)
CC = $(if $(shell command -v armv8m-tcc),armv8m-tcc,../../libs/tinycc/bin/armv8m-tcc)
endif
CFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
CFLAGS += $(ROOTFS_OPT_CFLAGS)
LDFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -L../../rootfs/lib
SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))
HEADERS = $(wildcard *.h)

TARGET = build/pioasm

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

# Rules
all: $(TARGET)

build/%.o: %.c $(HEADERS)
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

# The same sources for the build machine: `make host HOST_CC=gcc`.
HOST_CC ?= cc
host: build/host/pioasm

build/host/pioasm: $(SRCS) $(HEADERS)
	mkdir -p build/host
	$(HOST_CC) -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter $(SRCS) -o $@

# Compares the host build with outputs of the SDK's C++ pioasm (tests/run.sh).
test: build/host/pioasm
	sh tests/run.sh

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build

.PHONY: all host test install clean
