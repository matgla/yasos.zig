# mkfs.fat, mkfs.ext4 and mkfs.lfs.
#
#   make                 the yasos binaries (build_rootfs.sh passes CC=armv8m-tcc)
#   make host            build/host/mkfs.fat and build/host/mkfs.ext4, for a
#                        card or an image on a PC (apps/fdisk's image test)
#
# FatFs comes from libs/fatfs. Its sources are copied next to this directory's
# ffconf.h, because ff.h includes "ffconf.h" from its own directory first --
# the submodule's copy would win over ours.

CC ?= armv8m-tcc
HOST_CC ?= gcc
FATFS_SRC := libs/fatfs/source
LWEXT4 := ../../libs/lwext4

# lwext4 as the kernel builds it (source/fs/ext4/build.zig), minus the kernel's
# allocator hooks and multi-volume tables: one volume at a time here.
LWEXT4_DEFS = -DCONFIG_USE_DEFAULT_CFG=1 -DCONFIG_DEBUG_PRINTF=0 -DCONFIG_DEBUG_ASSERT=0 \
	-DCONFIG_JOURNALING_ENABLE=0 -DCONFIG_XATTR_ENABLE=0 -DCONFIG_EXTENTS_ENABLE=1 \
	-DCONFIG_HAVE_OWN_OFLAGS=0 -DCONFIG_HAVE_OWN_ERRNO=0 -DCONFIG_BLOCK_DEV_ENABLE_STATS=0 \
	-DCONFIG_BLOCK_DEV_CACHE_SIZE=8 -DCONFIG_EXT4_BLOCKDEVS_COUNT=1 -DCONFIG_EXT4_MOUNTPOINTS_COUNT=1
LWEXT4_SRCS = ext4.c ext4_balloc.c ext4_bcache.c ext4_bitmap.c ext4_blockdev.c \
	ext4_block_group.c ext4_crc32.c ext4_debug.c ext4_dir.c ext4_dir_idx.c ext4_extent.c \
	ext4_fs.c ext4_hash.c ext4_ialloc.c ext4_inode.c ext4_journal.c ext4_mbr.c ext4_mkfs.c \
	ext4_super.c ext4_trans.c ext4_xattr.c

CFLAGS = $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib \
	-Ibuild/ff -I. -I../../libs/littlefs -I$(LWEXT4)/include $(LWEXT4_DEFS) -DLFS_NO_INTRINSICS -DLFS_NO_WARN
CFLAGS += $(ROOTFS_OPT_CFLAGS)
LDFLAGS = -fvisibility=hidden $(ROOTFS_DEBUG_CFLAGS) -L../../rootfs/lib

HOST_CFLAGS = -O2 -Wall -Wextra -Wno-unused-parameter -DMKFS_HOST -D_FILE_OFFSET_BITS=64 -Ibuild/host/ff -I. \
	-I$(LWEXT4)/include $(LWEXT4_DEFS)
HOST_LWEXT4_CFLAGS = -Wno-sign-compare -Wno-implicit-fallthrough -Wno-unused-but-set-variable -Wno-stringop-truncation

FF_SRCS = ff.c ffunicode.c
FAT_OBJS = build/mkfs_fat.o build/blockdev.o build/diskio.o $(patsubst %.c, build/ff_%.o, $(FF_SRCS))
EXT4_OBJS = build/mkfs_ext4.o build/blockdev.o $(patsubst %.c, build/lwext4_%.o, $(LWEXT4_SRCS))
LITTLEFS_OBJS = build/mkfs_lfs.o build/lfs.o build/lfs_util.o

TARGET = build/mkfs.fat
TARGET_EXT4 = build/mkfs.ext4
TARGET_LITTLEFS = build/mkfs.lfs

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

all: $(TARGET) $(TARGET).elf $(TARGET_EXT4) $(TARGET_EXT4).elf

build/ff/.stamp: ffconf.h $(FATFS_SRC)/ff.c
	mkdir -p build/ff
	cp $(FATFS_SRC)/ff.c $(FATFS_SRC)/ff.h $(FATFS_SRC)/diskio.h $(FATFS_SRC)/ffunicode.c build/ff/
	cp ffconf.h build/ff/
	touch $@

build/host/ff/.stamp: ffconf.h $(FATFS_SRC)/ff.c
	mkdir -p build/host/ff
	cp $(FATFS_SRC)/ff.c $(FATFS_SRC)/ff.h $(FATFS_SRC)/diskio.h $(FATFS_SRC)/ffunicode.c build/host/ff/
	cp ffconf.h build/host/ff/
	touch $@

build/%.o: %.c blockdev.h build/ff/.stamp
	$(CC) $(CFLAGS) -c $< -o $@

build/ff_%.o: build/ff/.stamp
	$(CC) $(CFLAGS) -c build/ff/$*.c -o $@

build/lwext4_%.o: $(LWEXT4)/src/%.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

build/lfs.o: ../../libs/littlefs/lfs.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

build/lfs_util.o: ../../libs/littlefs/lfs_util.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(FAT_OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET).elf: $(FAT_OBJS)
	$(CC) $(LDFLAGS) -Wl,-oformat=elf32-littlearm $^ -o $@

$(TARGET_EXT4): $(EXT4_OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET_EXT4).elf: $(EXT4_OBJS)
	$(CC) $(LDFLAGS) -Wl,-oformat=elf32-littlearm $^ -o $@

$(TARGET_LITTLEFS): $(LITTLEFS_OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(TARGET_LITTLEFS).elf: $(LITTLEFS_OBJS)
	$(CC) $(LDFLAGS) -Wl,-oformat=elf32-littlearm $^ -o $@

host: build/host/mkfs.fat build/host/mkfs.ext4

build/host/mkfs.fat: mkfs_fat.c blockdev.c diskio.c blockdev.h build/host/ff/.stamp
	$(HOST_CC) $(HOST_CFLAGS) mkfs_fat.c blockdev.c diskio.c $(addprefix build/host/ff/, $(FF_SRCS)) -o $@

build/host/mkfs.ext4: mkfs_ext4.c blockdev.c blockdev.h $(addprefix $(LWEXT4)/src/, $(LWEXT4_SRCS)) $(wildcard $(LWEXT4)/include/*.h)
	mkdir -p build/host
	$(HOST_CC) $(HOST_CFLAGS) $(HOST_LWEXT4_CFLAGS) mkfs_ext4.c blockdev.c $(addprefix $(LWEXT4)/src/, $(LWEXT4_SRCS)) -o $@

install: $(TARGET) $(TARGET_EXT4) $(TARGET_LITTLEFS) $(TARGET_LITTLEFS).elf
	mkdir -p $(BINDIR)
	cp $(TARGET) $(TARGET_EXT4) $(TARGET_LITTLEFS) $(BINDIR)

clean:
	rm -rf build

.PHONY: all host install clean
