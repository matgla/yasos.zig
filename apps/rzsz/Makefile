CC ?= armv8m-tcc
CFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib -I.
CFLAGS += $(ROOTFS_OPT_CFLAGS)
LDFLAGS = -fvisibility=hidden $(ROOTFS_DEBUG_CFLAGS) -L../../rootfs/lib
COMMON_SRCS = crc32.c crc16.c terminal.c zmodem/zmodem.c
SRCS = main.c sz.c $(COMMON_SRCS)
OBJS = $(patsubst %.c, build/%.o, $(SRCS))
COMMON_OBJS = $(patsubst %.c, build/%.o, $(COMMON_SRCS))
LDFLAGS_ELF = $(LDFLAGS)

TARGET = build/rz
SZ = build/sz

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

ifeq ($(CC), armv8m-tcc)
    LDFLAGS_ELF += -Wl,-oformat=elf32-littlearm
endif


# Rules
all: $(TARGET) $(TARGET).elf $(SZ)

build/%.o: %.c
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): build/main.o $(COMMON_OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET).elf: build/main.o $(COMMON_OBJS)
	$(CC) $(LDFLAGS_ELF) $^ -o $@

$(SZ): build/sz.o $(COMMON_OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

install: $(TARGET) $(SZ)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(SZ) $(BINDIR)

clean:
	rm -rf build

-include $(OBJS:.o=.d)
