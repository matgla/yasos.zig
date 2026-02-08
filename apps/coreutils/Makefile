CC ?= armv8m-tcc
CFLAGS = -fPIE -fpie -g -mcpu=cortex-m33 -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
LDFLAGS = -fpie -fPIE -fvisibility=hidden -g -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4, -Wl,-oformat=yaff -L../../rootfs/lib
SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: build/touch

prepare:
	mkdir -p build

build/touch.o: touch.c prepare
	$(CC) $(CFLAGS) -c $< -o build/touch.o

build/touch: build/touch.o
	$(CC) $(LDFLAGS) $^ -o $@


install: build/touch
	mkdir -p $(BINDIR)
	cp build/touch $(BINDIR)

clean:
	rm -rf build