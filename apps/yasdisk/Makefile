#
# yasdisk Makefile
# MBR Partition Editor
#

CC ?= armv8m-tcc
CFLAGS = -g -fvisibility=hidden -Wall -Wextra
LDFLAGS = -g -fvisibility=hidden

SRCS = main.c mbr.c ui.c
OBJS = $(patsubst %.c, build/%.o, $(SRCS))

ifeq ($(CC), armv8m-tcc)
CFLAGS += -I../../rootfs/usr/include
LDFLAGS += -L../../rootfs/lib -lncurses
else
# Use system ncurses for host builds
LDFLAGS += -lncurses
endif

TARGET = build/yasdisk

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

TEST_TARGET := tests

# Rules
all: $(TARGET)

build/%.o: %.c
	mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)

clean:
	rm -rf build

# Run unit tests
.PHONY: test
ut: $(TARGET)
	$(MAKE) -C $(TEST_TARGET) run

# Integration tests
.PHONY: integration
integration: $(TARGET)
	$(MAKE) -C $(TEST_TARGET) integration

# All tests
.PHONY: test
test: ut integration

.PHONY: all clean install
