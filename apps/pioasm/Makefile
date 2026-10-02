CC ?= armv8m-tcc
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

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build
