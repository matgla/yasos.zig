CC ?= armv8m-tcc
CFLAGS = -fPIE -fpie $(ROOTFS_DEBUG_CFLAGS) -mcpu=cortex-m33 -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
CFLAGS += $(ROOTFS_OPT_CFLAGS)
LDFLAGS = -fpie -fPIE -fvisibility=hidden $(ROOTFS_DEBUG_CFLAGS) -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4, -Wl,-oformat=yaff -L../../rootfs/lib
SRCS = $(wildcard ccowsay/*.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET = build/cowsay

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(TARGET)

build/%.o: %.c
	mkdir -p build/ccowsay
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build
