CC ?= tcc 
CFLAGS = -std=c11 -Wall -gdwarf -fpic -pedantic -nostdlib -nostdinc -I. -I../../rootfs/usr/include -L../../rootfs/lib -Iinclude
LDFLAGS_STATIC = -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4 -nostdlib -Wl,-oformat=yaff
LDFLAGS = -shared -fPIC -gdwarf ${LDFLAGS_STATIC}

SRCS = $(wildcard *.c)

OBJS = $(patsubst %.c, build/%.o, $(SRCS))

TARGET_SHARED = build/libm.so
TARGET_STATIC = build/libm.a

PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(TARGET_SHARED) $(TARGET_STATIC)

prepare: 
	mkdir -p build

build/%.o: %.c prepare
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET_SHARED): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET_STATIC): $(OBJS)
	ar rcs $@ $^

install: $(TARGET_SHARED) $(TARGET_STATIC) 
	mkdir -p $(LIBDIR)
	cp $(TARGET_SHARED) $(LIBDIR)
	cp $(TARGET_STATIC) $(LIBDIR)

	cp include/*.h $(INCLUDEDIR)

clean:
	rm -rf build