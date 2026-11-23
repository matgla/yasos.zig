#
# ptracetest Makefile -- built for the board with the cross tcc.
#

CC ?= armv8m-tcc

CFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden
# tcc is safe by default (yasc, -Wall, unsafe C as errors); this code is
# regular C until it is ported, so -ccompat whenever CC is a tcc.
CFLAGS += $(if $(findstring tcc,$(notdir $(firstword $(CC)))),-ccompat)
LDFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden

ifeq ($(CC), armv8m-tcc)
CFLAGS += -I../../rootfs/usr/include
LDFLAGS += -L../../rootfs/lib
endif

CFLAGS += $(ROOTFS_OPT_CFLAGS)

TARGET = build/ptracetest

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

all: $(TARGET)

build/ptracetest.o: ptracetest.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): build/ptracetest.o
	$(CC) $(LDFLAGS) $^ -o $@

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build

.PHONY: all clean install
