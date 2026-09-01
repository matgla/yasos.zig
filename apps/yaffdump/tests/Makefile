#
# yaffdump tests
#
# Two layers: unit tests that need nothing but a host compiler, and the
# differential test that disassembles the whole rootfs twice -- once with
# yaffdump, once with arm-none-eabi-objdump -- and diffs the two listings.
# The second one is the real specification; the first one is what runs
# anywhere and pins the cases a corpus cannot be relied on to contain.
#

CC = gcc
CFLAGS = -Wall -Wextra -Werror -std=c11 -I. -I.. -I../../../libs/tinycc/source/obj
LDFLAGS =

ifeq ($(CC), gcc)
CFLAGS += -fsanitize=address
LDFLAGS += -fsanitize=address
endif

TEST_NAMES = thumb_tests
TEST_BINS = $(patsubst %,build/%,$(TEST_NAMES))

OBJDUMP ?= arm-none-eabi-objdump
ROOTFS = ../../../rootfs

all: run

build:
	mkdir -p build

build/thumb_tests: thumb_tests.c ../thumb.c ../thumb.h acutest.h | build
	$(CC) $(CFLAGS) -o $@ thumb_tests.c ../thumb.c $(LDFLAGS)

.PHONY: unit
unit: $(TEST_BINS)
	@for test in $(TEST_NAMES); do \
		echo "Running build/$$test..."; \
		./build/$$test || exit 1; \
	done

# The host build of the tool the differential test drives.
.PHONY: host
host:
	$(MAKE) -C .. CC=gcc

.PHONY: differential
differential: host
	@if ! command -v $(OBJDUMP) >/dev/null 2>&1; then \
		echo "skipping the differential test: $(OBJDUMP) is not installed"; \
	elif [ ! -d $(ROOTFS)/usr/bin ]; then \
		echo "skipping the differential test: no rootfs built yet"; \
	else \
		./diff_objdump.py --show 8; \
	fi

.PHONY: run
run: unit differential

clean:
	rm -rf build __pycache__

.PHONY: all clean
