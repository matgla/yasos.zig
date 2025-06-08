CC ?= armv8m-tcc
CFLAGS = -fPIE -fpie -g -mcpu=cortex-m33 -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
LDFLAGS = -fpie -fPIE -fvisibility=hidden -g -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4, -Wl,-oformat=yaff
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

build/ls: build/ls.o
	$(CC) $(LDFLAGS) $^ -o $@

build/ls.elf: build/ls.o
	$(CC) $(LDFLAGS) $^ -Wl,-oformat=elf32-littlearm -o $@

build/cat: build/cat.o
	$(CC) $(LDFLAGS) $^ -o $@
build/echo: build/echo.o
	$(CC) $(LDFLAGS) $^ -o $@


install: build/ls build/cat build/echo build/ls.elf
	mkdir -p $(BINDIR)
	cp build/ls $(BINDIR)
	cp build/cat $(BINDIR)
	cp build/echo $(BINDIR)

clean:
	rm -rf build