CC ?= tcc 
CFLAGS = -std=c11 -Wall -Iinclude -Ilibs -g -fpic -pedantic -nostdlib -nostdinc -I../../source/sys/include -Ilibs/neatlibc
LDFLAGS_STATIC = -nostdlib
LDFLAGS = -shared -fPIC -g ${LDFLAGS_STATIC} 

ifeq ($(CC), armv8m-tcc)
CFLAGS += -DYASLIBC_ARM_SVC_TRIGGER
LDFLAGS += -Wl,-image-base=0x0 -Wl,-section-alignment=0x4
endif

SRCS = libs/neatlibc/atoi.c \
	libs/neatlibc/ctype.c \
	libs/neatlibc/dirent.c \
	libs/neatlibc/errno.c \
	libs/neatlibc/isatty.c \
	libs/neatlibc/localtime.c \
	libs/neatlibc/memtst.c \
	$(wildcard *.c) 

OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET_SHARED = build/libc.so
TARGET_STATIC = build/libc.a

PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(TARGET_SHARED) $(TARGET_STATIC)

build/%.o: %.c
	mkdir -p build
	mkdir -p build/libs/neatlibc
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET_SHARED): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET_STATIC): $(OBJS)
	ar rcs $@ $^

install: $(TARGET_SHARED) $(TARGET_STATIC)
	mkdir -p $(LIBDIR)
	cp $(TARGET_SHARED) $(LIBDIR)
	cp $(TARGET_STATIC) $(LIBDIR)
	cp -r include/* $(INCLUDEDIR)
	mkdir -p $(INCLUDEDIR)/printf
	cp -r libs/printf/printf.h $(INCLUDEDIR)/printf/printf.h




clean:
	rm -rf build