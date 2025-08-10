CC ?= gcc
CFLAGS = -g -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib -Ilibs/fatfs/source -I.
LDFLAGS = -fvisibility=hidden -g
SRCS = $(wildcard *.c) libs/fatfs/source/ff.c libs/fatfs/source/ffsystem.c libs/fatfs/source/ffunicode.c
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET = build/mkfs.fat

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(TARGET) $(TARGET).elf

build/%.o: %.c
	mkdir -p build/libs/fatfs/source
	rm  -f libs/fatfs/source/ffconf.h
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET).elf: $(OBJS)
	$(CC) $(LDFLAGS) -Wl,-oformat=elf32-littlearm $^ -o $@

install: $(TARGET) 
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build