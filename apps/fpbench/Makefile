# fpbench -- one source, four builds, differing only in how floating point is
# reached.  See main.c for what each arm is and why the set is what it is.
#
# The optimisation level is pinned here rather than taken from
# ROOTFS_OPT_CFLAGS: the arms have to be compared against each other, and a
# rootfs built at a different -O would move all four columns together while
# looking like it had not.  Debug flags still come from the build, since they
# do not change code generation.
CC ?= armv8m-tcc
BASE_CFLAGS = -O2 $(ROOTFS_DEBUG_CFLAGS) -fvisibility=hidden -I../../rootfs/usr/include -L../../rootfs/lib
BASE_LDFLAGS = -O2 -fvisibility=hidden $(ROOTFS_DEBUG_CFLAGS) -L../../rootfs/lib

# The hardware arms name no -mfpu of their own.  The toolchain is built with
# the target's FPU as its compiled-in default (CONFIG_TCC_DEFAULT_FPU, set from
# CONFIG_BUILD_USERSPACE_FP_MFPU), so "no flag" already means "this board's FP
# hardware" -- and on a build with the hardware turned off these arms collapse
# onto the soft one, which is the honest answer rather than a link error.
MODE_FLAGS_soft     = -mfpu=none -mfp-lib=shared
MODE_FLAGS_hwlib    = -mfp-inline=none -mfp-lib=shared
MODE_FLAGS_hwstatic = -mfp-inline=none -mfp-lib=static
MODE_FLAGS_inline   = -mfp-lib=shared

MODES = soft hwlib hwstatic inline

TARGETS = $(addprefix build/fpbench-,$(MODES))
ELVES = $(addsuffix .elf,$(TARGETS))

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

ifeq ($(CC), armv8m-tcc)
    LDFLAGS_ELF_EXTRA = -Wl,-oformat=elf32-littlearm
endif

all: $(TARGETS) $(ELVES)

# One rule per mode: an implicit rule cannot reach $(MODE_FLAGS_<mode>) with
# the mode as a stem, and spelling the four out keeps the flags next to the
# name they belong to.
define FPBENCH_MODE_RULE
build/fpbench-$(1): main.c | build
	$$(CC) $$(BASE_CFLAGS) $$(MODE_FLAGS_$(1)) -DFPBENCH_MODE='"$(1)"' -c main.c -o build/$(1).o
	$$(CC) $$(BASE_LDFLAGS) $$(MODE_FLAGS_$(1)) build/$(1).o -o $$@

build/fpbench-$(1).elf: build/fpbench-$(1)
	$$(CC) $$(BASE_LDFLAGS) $$(MODE_FLAGS_$(1)) $$(LDFLAGS_ELF_EXTRA) build/$(1).o -o $$@
endef

$(foreach mode,$(MODES),$(eval $(call FPBENCH_MODE_RULE,$(mode))))

build:
	mkdir -p build

install: $(TARGETS)
	mkdir -p $(BINDIR)
	cp $(TARGETS) $(BINDIR)
	cp fpbench.sh $(BINDIR)/fpbench.sh

clean:
	rm -rf build

.PHONY: all install clean
