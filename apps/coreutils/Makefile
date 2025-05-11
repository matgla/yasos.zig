CC ?= armv8m-tcc
CFLAGS = -fPIE -fpie -g -mcpu=cortex-m33 -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
LDFLAGS = -fpie -fPIE -fvisibility=hidden -g -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4 
SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: ls 

prepare: 
	mkdir -p build

build/ls.o: ls.c prepare
	$(CC) $(CFLAGS) -c $< -o build/ls.o

build/cat.o: cat.c prepare
	$(CC) $(CFLAGS) -c $< -o build/cat.o

build/echo.o: echo.c prepare
	$(CC) $(CFLAGS) -c $< -o build/echo.o

build/ls.elf: build/ls.o
	$(CC) $(LDFLAGS) $^ -o $@
build/cat.elf: build/cat.o
	$(CC) $(LDFLAGS) $^ -o $@
build/echo.elf: build/echo.o
	$(CC) $(LDFLAGS) $^ -o $@


install: build/ls.elf build/cat.elf build/echo.elf
	mkdir -p $(BINDIR)
	cp build/ls.elf $(BINDIR)
	cp build/cat.elf $(BINDIR)
	cp build/echo.elf $(BINDIR)

clean:
	rm -rf build