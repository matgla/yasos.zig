#
# strip Makefile
#
# Builds for the board with the cross tcc by default.  `make host` builds the
# same source with gcc into build-host/ (a PC strips images before they go to
# the board), and `make test` runs the tests against that host build.
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

TARGET = build/strip

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

all: $(TARGET)

build/strip.o: strip.c $(YAFF_INCLUDE)/tccyaff.h
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): build/strip.o
	$(CC) $(LDFLAGS) $^ -o $@

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

.PHONY: host
host: build-host/strip

build-host/strip: strip.c $(YAFF_INCLUDE)/tccyaff.h
	mkdir -p build-host
	gcc -O2 -Wall -Wextra -Werror -std=c11 -D_DEFAULT_SOURCE -I$(YAFF_INCLUDE) $< -o $@

.PHONY: test
test: build-host/strip
	python3 -m pytest -q tests

clean:
	rm -rf build build-host tests/build

.PHONY: all clean install
