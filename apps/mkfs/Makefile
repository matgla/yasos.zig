CC ?= gcc
CFLAGS = -g -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib -Ilibs/fatfs/source -I../../libs/littlefs -I. -DLFS_NO_INTRINSICS -DLFS_NO_WARN
LDFLAGS = -fvisibility=hidden -g
FAT_SRCS = mkfs_fat.c platform.c libs/fatfs/source/ff.c libs/fatfs/source/ffsystem.c libs/fatfs/source/ffunicode.c
FAT_OBJS = $(patsubst %.c, build/%.o, $(FAT_SRCS))

LITTLEFS_SRCS = mkfs_lfs.c ../../libs/littlefs/lfs.c ../../libs/littlefs/lfs_util.c
LITTLEFS_OBJS = $(patsubst %.c, build/%.o, $(notdir $(LITTLEFS_SRCS)))

# Tell Make where to find source files
vpath %.c . ../../libs/littlefs


TARGET = build/mkfs.fat
TARGET_LITTLEFS = build/mkfs.lfs

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
INCLUDEDIR ?= $(PREFIX)/include

# Rules
all: $(TARGET) $(TARGET).elf

build/%.o: %.c
	mkdir -p build/libs/fatfs/source
	rm  -f libs/fatfs/source/ffconf.h
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(FAT_OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET_LITTLEFS): $(LITTLEFS_OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET).elf: $(FAT_OBJS)
	$(CC) $(LDFLAGS) -Wl,-oformat=elf32-littlearm $^ -o $@

$(TARGET_LITTLEFS).elf: $(LITTLEFS_OBJS)
	$(CC) $(LDFLAGS) -Wl,-oformat=elf32-littlearm $^ -o $@

install: $(TARGET) $(TARGET_LITTLEFS) $(TARGET_LITTLEFS).elf $(TARGET).elf
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)
	cp $(TARGET_LITTLEFS) $(BINDIR)

clean:
	rm -rf build