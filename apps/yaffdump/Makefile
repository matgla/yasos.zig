#
# yaffdump Makefile
#
# Builds for the board with the cross tcc by default, and for the host with
# `make CC=gcc` -- the host build is what the differential test in tests/ runs
# against arm-none-eabi-objdump, so the same sources have to compile both ways.
#

CC ?= armv8m-tcc

# The module layout comes from the compiler's own header, never from a copy.
YAFF_INCLUDE = ../../libs/tinycc/source/obj

CFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -I$(YAFF_INCLUDE)
LDFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden

ifeq ($(CC), armv8m-tcc)
CFLAGS += -I../../rootfs/usr/include
LDFLAGS += -L../../rootfs/lib
else
CFLAGS += -Wall -Wextra -std=c11
endif

CFLAGS += $(ROOTFS_OPT_CFLAGS)

SRCS = main.c yaff.c thumb.c
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET = build/yaffdump

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

all: $(TARGET)

build/%.o: %.c yaff.h thumb.h
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

# The host build and the differential test against objdump.
.PHONY: test
test:
	$(MAKE) -C tests run

clean:
	rm -rf build
	$(MAKE) -C tests clean

.PHONY: all clean install
