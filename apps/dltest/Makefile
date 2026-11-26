#
# dltest Makefile -- dl* checks and the library they open, built for the
# board with the cross tcc.  tests/smoke/dl_test.py runs build/dltest.
#

CC ?= armv8m-tcc

CFLAGS = $(ROOTFS_DEBUG_CFLAGS)
# tcc is safe by default (yasc, -Wall, unsafe C as errors); the casts from
# dlsym's void * are regular C, so -ccompat whenever CC is a tcc.
CFLAGS += $(if $(findstring tcc,$(notdir $(firstword $(CC)))),-ccompat)
LDFLAGS = $(ROOTFS_DEBUG_CFLAGS)

ifeq ($(CC), armv8m-tcc)
CFLAGS += -I../../rootfs/usr/include
LDFLAGS += -L../../rootfs/lib
endif

CFLAGS += $(ROOTFS_OPT_CFLAGS)

TARGET = build/dltest
LIBRARY = build/libdltest.so

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib

all: $(TARGET) $(LIBRARY)

build/dltest.o: dltest.c
	mkdir -p build
	$(CC) $(CFLAGS) -fvisibility=hidden -c $< -o $@

$(TARGET): build/dltest.o
	$(CC) $(LDFLAGS) -fvisibility=hidden $^ -o $@

# Every symbol exported: dltest looks them up by name.
build/libdltest.o: libdltest.c
	mkdir -p build
	$(CC) $(CFLAGS) -fPIC -c $< -o $@

$(LIBRARY): build/libdltest.o
	$(CC) $(LDFLAGS) -shared -fPIC -Wl,-oformat=yaff $^ -o $@

install: $(TARGET) $(LIBRARY)
	mkdir -p $(BINDIR) $(LIBDIR)
	cp $(TARGET) $(BINDIR)
	cp $(LIBRARY) $(LIBDIR)

clean:
	rm -rf build
