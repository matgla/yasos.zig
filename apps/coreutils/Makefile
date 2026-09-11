CC ?= armv8m-tcc
CFLAGS = -fPIE -fpie $(ROOTFS_DEBUG_CFLAGS) -mcpu=cortex-m33 -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
CFLAGS += $(ROOTFS_OPT_CFLAGS)
LDFLAGS = -fpie -fPIE -fvisibility=hidden $(ROOTFS_DEBUG_CFLAGS) -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4, -Wl,-oformat=yaff -L../../rootfs/lib

# One binary per .c here, so a new command is a new file and nothing else.
SRCS = $(wildcard *.c)
BINS = $(patsubst %.c, build/%, $(SRCS))

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(BINS)

prepare:
	mkdir -p build

build/%.o: %.c | prepare
	$(CC) $(CFLAGS) -c $< -o $@

build/%: build/%.o
	$(CC) $(LDFLAGS) $^ -o $@

install: $(BINS)
	mkdir -p $(BINDIR)
	cp $(BINS) $(BINDIR)

clean:
	rm -rf build

# Without this, make treats build/%.o as an intermediate of the chained
# implicit rules above and deletes it after each link, so every build is a full
# rebuild.
.SECONDARY:

.PHONY: all prepare install clean
