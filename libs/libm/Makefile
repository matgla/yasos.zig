# Command-line CC still overrides this, but plain `make` should use TinyCC.
CC = tcc
CFLAGS = -std=c11 -Wall -gdwarf -fpic -pedantic -nostdlib -nostdinc -I. -I../../rootfs/usr/include -L../../rootfs/lib -Iinclude
CFLAGS += $(ROOTFS_OPT_CFLAGS)
LDFLAGS_STATIC = -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4 -nostdlib -Wl,-oformat=yaff
# -nostdlib skips standard libs (libc, etc.) but tcc still auto-links
# compiler runtime (libtcc1, libsoftfp) which provide __aeabi_* helpers.
LDFLAGS = -shared -fPIC -gdwarf ${LDFLAGS_STATIC}
LIBTCC1_PATH = $(firstword $(wildcard ../tinycc/armv8m-libtcc1.a ../tinycc/lib/tcc/armv8m-libtcc1.a))
# No explicit FP archive here: tcc picks the runtime that matches its -mfpu
# (libsoftfp / libvfpv4sp / librp2350fp) as part of the compiler runtime that
# -nostdlib keeps. Naming libsoftfp.a here used to put the software versions
# first on the command line, so libm -- the most FP-heavy library in the tree --
# kept calling soft float even in a hardware FP build.
RUNTIME_LIBS = $(LIBTCC1_PATH)

SRCS = $(wildcard *.c)

OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET_SHARED = build/libm.so
TARGET_STATIC = build/libm.a

PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(TARGET_SHARED) $(TARGET_STATIC)

prepare:
	mkdir -p build

build/%.o: %.c | prepare
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET_SHARED): $(OBJS)
	$(CC) $(LDFLAGS) $^ $(RUNTIME_LIBS) -o $@

$(TARGET_STATIC): $(OBJS)
	ar rcs $@ $^

install: $(TARGET_SHARED) $(TARGET_STATIC)
	mkdir -p $(LIBDIR)
	cp $(TARGET_SHARED) $(LIBDIR)
	cp $(TARGET_STATIC) $(LIBDIR)

	cp include/*.h $(INCLUDEDIR)

test:
	$(MAKE) -C tests test

clean:
	rm -rf build
	$(MAKE) -C tests clean
