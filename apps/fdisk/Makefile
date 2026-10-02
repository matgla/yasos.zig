# fdisk: edit a disk's MBR partition table (see fdisk.c).
#
#   make                 the yasos binary (build_rootfs.sh passes CC=armv8m-tcc)
#   make host            build/host/fdisk, for a card or an image on a PC
#   make test            host unit tests of the table code, and the card
#                        image test of fdisk + mkfs + usr/bin/cardreformat

CC ?= armv8m-tcc
HOST_CC ?= gcc

CFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib -I.
CFLAGS += $(ROOTFS_OPT_CFLAGS)
LDFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -L../../rootfs/lib

HOST_CFLAGS = -O2 -Wall -Wextra -D_FILE_OFFSET_BITS=64 -I.

SRCS = fdisk.c mbr.c

TARGET = build/fdisk
HOST_TARGET = build/host/fdisk

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

all: $(TARGET)

build/%.o: %.c mbr.h
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(patsubst %.c, build/%.o, $(SRCS))
	$(CC) $(LDFLAGS) $^ -o $@

host: $(HOST_TARGET)

$(HOST_TARGET): $(SRCS) mbr.h
	mkdir -p build/host
	$(HOST_CC) $(HOST_CFLAGS) $(SRCS) -o $@

build/host/mbr_tests: tests/mbr_tests.c mbr.c mbr.h
	mkdir -p build/host
	$(HOST_CC) $(HOST_CFLAGS) tests/mbr_tests.c mbr.c -o $@

test: build/host/mbr_tests $(HOST_TARGET)
	./build/host/mbr_tests
	$(MAKE) -s -C ../mkfs host
	./tests/image_test.sh

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build

.PHONY: all host test install clean
