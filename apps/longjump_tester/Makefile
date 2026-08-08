CC ?= armv8m-tcc
CFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
CFLAGS += $(ROOTFS_OPT_CFLAGS)
LDFLAGS = -fvisibility=hidden $(ROOTFS_DEBUG_CFLAGS) -L../../rootfs/lib
SRCS = $(wildcard *.c)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))
LDFLAGS_ELF = $(LDFLAGS)

TARGET = build/jump_test

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

ifeq ($(CC), armv8m-tcc)
    LDFLAGS_ELF += -Wl,-oformat=elf32-littlearm
endif


# Rules
all: $(TARGET) $(TARGET).elf

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET).elf: $(OBJS)
	$(CC) $(LDFLAGS_ELF) $^ -o $@

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build
