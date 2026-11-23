CC ?= armv8m-tcc
CFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
# tcc is safe by default (yasc, -Wall, unsafe C as errors); this code is
# regular C until it is ported, so -ccompat whenever CC is a tcc.
CFLAGS += $(if $(findstring tcc,$(notdir $(firstword $(CC)))),-ccompat)
CFLAGS += $(ROOTFS_OPT_CFLAGS)
LDFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -L../../rootfs/lib
SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET = build/time

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(TARGET)

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build
