#!/bin/bash

if [[ "$(uname)" == "Darwin" ]]; then
GETOPT_CMD="/opt/homebrew/Cellar/gnu-getopt/2.41/bin/getopt"
else
GETOPT_CMD="/usr/bin/getopt"
fi
OPTIONS=co:d
LONGOPTIONS=clear,output:,debug-regalloc,debug,no-kernel

PARSED=$($GETOPT_CMD --options $OPTIONS --longoptions $LONGOPTIONS --name "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    # If getopt has complained about anything, it will return a non-zero exit status
    exit 2
fi

eval set -- "$PARSED"

if [[ ! -v CC ]]; then
  CC=armv8m-tcc
else
  echo "Using CC: $CC"
fi
# Default value
CLEAR=false
BUILD_IMAGE=false
DEBUG_REGALLOC=false
DEBUG_TCC=false
# --tcc-ab-knobs: compile the getenv-driven bisect knobs (TCC_DISABLE_PASS,
# TCC_NO_REHEARSAL, TCC_KEEP_FWD_DRY, ...) back into the DEVICE compiler while
# leaving everything else exactly as a release build: TCC_DEBUG stays 0 and the
# optimization level stays -O2.  --debug also turns TCC_DEBUG on, which changes
# what the compiler does; that is the wrong tool for reproducing a specific
# fault and then bisecting it, because the arm you measure is not the arm that
# failed.  The knobs are inert unless their env var is set, so the only
# difference from a release build is ~14.6 KB of .text.
TCC_AB_KNOBS=false
# Precompiled headers trade flash space for a compile-time speedup that turned
# out to be too small to justify the size on rp2350. Off by default; re-enable
# with --with-pch.
GENERATE_PCH=false
# When a rootfs image is produced (-o), also rebuild the kernel so the freshly
# built image (which the kernel .incbin's) is actually embedded. Without this the
# kernel/QEMU silently runs a STALE romfs (e.g. an old armv8m-tcc) after a tcc or
# rootfs change. Opt out with --no-kernel (e.g. when the caller runs zig build
# itself, like scripts/run_qemu_smoke.sh).
REBUILD_KERNEL=true

# Process the options
while true; do
    case "$1" in
        -c|--clear)
            CLEAR=true
            shift
            ;;
        -o|--output)
            BUILD_IMAGE=true
            OUTPUT_FILE=$2
            shift 2
            ;;
        -d|--debug-regalloc)
            DEBUG_REGALLOC=true
            shift
            ;;
        --debug)
          DEBUG_TCC=true
          shift
          ;;
        --tcc-ab-knobs)
          TCC_AB_KNOBS=true
          shift
          ;;
        --no-kernel)
          REBUILD_KERNEL=false
          shift
          ;;
        --with-pch)
          GENERATE_PCH=true
          shift
          ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1"
            exit 3
            ;;
    esac
done
SCRIPT_DIR=$(dirname "$(realpath "$0")")

PREFIX=$SCRIPT_DIR/rootfs/usr
TARGET_BUILD_EXTRA_CFLAGS=""
if ! $DEBUG_TCC; then
  TARGET_BUILD_EXTRA_CFLAGS="-O2"
fi
# Debug info is opt-in (--debug): -g bloats every binary in the image and, under
# tcc, pins otherwise-collectable code (do_compact keeps dead late-reopt bodies
# when debug info references them). Makefiles receive this as ROOTFS_DEBUG_CFLAGS
# and must not hardcode -g themselves.
DEBUG_CFLAGS=""
if $DEBUG_TCC; then
  DEBUG_CFLAGS="-g"
fi

# ---- Userspace floating point (KConfig: CONFIG_BUILD_USERSPACE_HARDWARE_FP) ----
#
# Rather than sprinkle -mfpu across ~20 Makefiles (half of which pass no CFLAGS
# of their own) and every link line, the mode is compiled into the toolchain:
# both tcc stages get -DCONFIG_TCC_DEFAULT_FPU=<enum>, so `armv8m-tcc` and the
# on-device `tcc` default to that FPU. That reaches libraries, applications,
# tcc's own bootstrap, and programs compiled later on the device, and makes the
# link step select the matching __aeabi_* runtime (librp2350fp / libvfpv4sp /
# libsoftfp) on its own.
#
# The float ABI is deliberately NOT changed: -mfpu only says which instructions
# may be emitted inline. FP arguments stay in general-purpose registers, so
# objects and .so files built before and after the switch stay compatible.
KERNEL_CONFIG_JSON="$SCRIPT_DIR/config/target/config.json"
FP_MODE="soft"
TCC_FP_DEFINE=""
if [ -f "$KERNEL_CONFIG_JSON" ] && command -v python3 >/dev/null 2>&1; then
  FP_MODE=$(python3 - "$KERNEL_CONFIG_JSON" <<'PYEOF'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    print("soft")
    sys.exit(0)
if not cfg.get("build_userspace_hardware_fp"):
    print("soft")
else:
    print(cfg.get("build_userspace_fp_mfpu") or "soft")
PYEOF
)
fi
case "$FP_MODE" in
  soft)
    ;;
  rp2350|rp2350-dcp)
    TCC_FP_DEFINE="-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_RP2350"
    ;;
  fpv5-sp-d16)
    TCC_FP_DEFINE="-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_FPV5_SP_D16"
    ;;
  fpv5-d16)
    TCC_FP_DEFINE="-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_FPV5_D16"
    ;;
  fpv4-sp-d16)
    TCC_FP_DEFINE="-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_FPV4_SP_D16"
    ;;
  *)
    echo "ERROR: unknown CONFIG_BUILD_USERSPACE_FP_MFPU '$FP_MODE'."
    echo "       Add it to the case in build_rootfs.sh (and to tcc's -mfpu parser)."
    exit 1
    ;;
esac
echo "Userspace floating point: $FP_MODE"

# Switching FP mode changes code generation for every object, but make only
# looks at timestamps -- an incremental build would silently keep soft-float
# objects and link them against a hardware FP runtime. Force the full rebuild
# the switch actually requires.
FP_MODE_STAMP="$SCRIPT_DIR/libs/tinycc/.yasos-build/fp-mode"
if [ -f "$FP_MODE_STAMP" ] && [ "$(cat "$FP_MODE_STAMP")" != "$FP_MODE" ]; then
  echo "Userspace floating point changed ($(cat "$FP_MODE_STAMP") -> $FP_MODE): forcing a clean rebuild."
  CLEAR=true
fi

echo "Building rootfs from $SCRIPT_DIR..."
cd $SCRIPT_DIR

if $CLEAR; then
  echo "Clearing..."
  rm -rf rootfs
  rm -rf apps/shell/build
  rm -rf apps/coreutils/build
  rm -rf apps/cowsay/build
  rm -rf apps/ascii_animations/build
  rm -rf apps/textvaders/build
  rm -rf apps/hello_world/build
  rm -rf libs/libc/build
  rm -rf libs/libdl/build
  rm -rf libs/pthread/build
  rm -rf libs/yasos_curses/build
  rm -rf apps/textvaders/build
  rm -rf apps/hexdump/build
  rm -rf libs/libm/build
  rm -rf apps/yasvi/build
  rm -rf apps/mkfs/build
  rm -rf apps/longjump_tester/build
  rm -rf apps/sdbench/build
  rm -rf apps/syscallbench/build

  rm -rf libs/tinycc/bin
  rm -rf libs/tinycc/.yasos-build
  ( cd libs/tinycc && make clean ) || true
  ( cd apps/zork && make clean ) || true
fi
mkdir -p rootfs
mkdir -p rootfs/usr/include
mkdir -p rootfs/usr/lib
mkdir -p rootfs/proc
mkdir -p rootfs/root
mkdir -p rootfs/home
mkdir -p rootfs/mnt
cd rootfs
if [ ! -e lib ] && [ ! -L lib ]; then
  ln -s usr/lib lib
fi
if [ ! -e bin ] && [ ! -L bin ]; then
  ln -s usr/bin bin
fi
ls -lah
pwd
cd ..
# /tmp is an empty directory, not a symlink: the kernel mounts the hybrid
# RAM/disk filesystem over it at boot (CONFIG_TMPFS_ENABLE, source/main.zig), and
# a mount point has to be a real directory — the VFS verifies it exists in the
# parent filesystem, and resolving a romfs symlink to /root/tmp inside the romfs
# finds nothing. Bodies too large for the arena still end up in
# CONFIG_TMPFS_SPILL_DIRECTORY on the writable rootfs.
rm -rf rootfs/tmp
mkdir -p rootfs/tmp
cp $SCRIPT_DIR/hello_world.c rootfs/usr
cp $SCRIPT_DIR/hello_script.sh rootfs/usr

mkdir -p rootfs/dev
pwd
cd libs

TINYCC_DIR="$SCRIPT_DIR/libs/tinycc"
TINYCC_STAMP_DIR="$TINYCC_DIR/.yasos-build"

touch_stamp()
{
  mkdir -p "$TINYCC_STAMP_DIR"
  touch "$1"
}

tinycc_sources_newer_than()
{
  local stamp_file="$1"

  if [ ! -f "$stamp_file" ]; then
    return 0
  fi

  # Compare real source files against the stamp written after a successful
  # build.  Exclude directories and files that are generated during the
  # build itself (config.h, config.mak, conftest.c, include/, .yasos-build/).
  find "$TINYCC_DIR" \
    \( -path "$TINYCC_DIR/.git" \
       -o -path "$TINYCC_DIR/.github" \
       -o -path "$TINYCC_DIR/.pytest_cache" \
       -o -path "$TINYCC_DIR/.venv" \
       -o -path "$TINYCC_DIR/.yasos-build" \
       -o -path "$TINYCC_DIR/bin" \
       -o -path "$TINYCC_DIR/build" \
       -o -path "$TINYCC_DIR/include" \
       -o -path "$TINYCC_DIR/lib" \
       -o -path "$TINYCC_DIR/rootfs" \) -prune -o \
    -type f \( -name '*.c' \
       -o -name '*.h' \
       -o -name '*.s' \
       -o -name '*.S' \
       -o -name 'Makefile' \
       -o -name 'configure' \
       -o -name 'VERSION' \) \
    ! -name 'config.h' \
    ! -name 'config.mak' \
    ! -name 'conftest.c' \
    -newer "$stamp_file" -print -quit | grep -q .
}

build_cross_compiler()
{
  echo "Building cross compiler..."
  cd tinycc
  if $CLEAR; then
    # Only force a fresh tinycc rebuild when explicitly requested.
    make distclean 2>/dev/null || true
    rm -f config.h config.mak *.o
  fi
  mkdir -p bin
  # Use explicit workspace paths to avoid system newlib
  YASOS_SYSROOT="$SCRIPT_DIR/rootfs"
  YASOS_LIBPATHS="$SCRIPT_DIR/rootfs/usr/lib:{B}:$SCRIPT_DIR/rootfs/lib"
  YASOS_CRTPREFIX="$SCRIPT_DIR/rootfs/usr/lib"
  # rootfs/usr/include first (the tcc intrinsic headers are mirrored there
  # byte-identically), so libc headers resolve on the first probe instead of
  # missing {B}/include with an ENOENT every time -- each failed open is a VFS
  # path-walk + dir scan on device.  {B}/include stays as fallback for tcclib.h.
  YASOS_SYSINCLUDES="$SCRIPT_DIR/rootfs/usr/include:{B}/include"

  CROSS_TCC_DEBUG_DEFINE="-DTCC_DEBUG=0"
  CROSS_EXTRA_CFLAGS="$CROSS_TCC_DEBUG_DEFINE -O2 -DTARGETOS_YasOS=1 -DCONFIG_TCC_BCHECK=0 -Wall -Werror"
  CROSS_CONFIG_DEBUG=""
  if $DEBUG_TCC; then
    CROSS_CONFIG_DEBUG="--debug --enable-O2"
    CROSS_TCC_DEBUG_DEFINE="-DTCC_DEBUG=1"
    CROSS_EXTRA_CFLAGS="$CROSS_TCC_DEBUG_DEFINE -g -O2 -DTARGETOS_YasOS=1 -DCONFIG_TCC_BCHECK=0 -Wall -Werror"
  fi
  if $DEBUG_REGALLOC; then
    CROSS_EXTRA_CFLAGS="$CROSS_EXTRA_CFLAGS -DTCC_REGALLOC_DEBUG"
  fi
  # Default -mfpu for everything this compiler builds (see the FP_MODE block
  # near the top). Empty when userspace floating point is soft.
  CROSS_EXTRA_CFLAGS="$CROSS_EXTRA_CFLAGS $TCC_FP_DEFINE"
  CROSS_STAMP_FILE="$TINYCC_STAMP_DIR/cross.stamp"

  if ! $CLEAR && [ -f "$CROSS_STAMP_FILE" ] && [ -f "$SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc" ] && ! tinycc_sources_newer_than "$CROSS_STAMP_FILE" && [ ! "$SCRIPT_DIR/build_rootfs.sh" -nt "$CROSS_STAMP_FILE" ]; then
    echo "Cross compiler already up to date."
    PATH=$SCRIPT_DIR/libs/tinycc/bin:$PATH
    cd ..
    return
  fi

  ./configure --extra-cflags="$CROSS_EXTRA_CFLAGS" \
    --enable-cross --config-asm=yes --config-bcheck=no --config-pie=yes --config-pic=yes \
    $CROSS_CONFIG_DEBUG \
    --prefix="$SCRIPT_DIR/libs/tinycc" \
    --sysroot="$YASOS_SYSROOT" \
    --libpaths="$YASOS_LIBPATHS" \
    --crtprefix="$YASOS_CRTPREFIX" \
    --sysincludepaths="$YASOS_SYSINCLUDES"
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  # Save cross-compiler config for later comparison with native build
  cp config.h config.h.cross
  # A previous run's native bootstrap (build_c_compiler) leaves ARM-target
  # objects in armv8m-arch/arm/libarm.a and the armv8m-*.o files. The nested
  # arch Makefile keys recompilation on source timestamps only — not on the
  # active CC — so a cross rebuild here would re-archive those ARM objects and
  # the host-gcc link of armv8m-tcc rejects them ("relocations in generic ELF
  # (EM: 40)" / "file in wrong format"). Drop the prior build objects so the
  # cross stage recompiles everything for the host. (Symmetric to the cleanup
  # in build_c_compiler before the native bootstrap.)
  # armv8m-source/ holds the relocated opt/backend objects (post source/opt
  # reorg) — dropping only armv8m-arch/armv8m-ir would reuse the other stage's
  # objects and fail the link with "unrecognized file type".
  rm -rf armv8m-arch armv8m-ir armv8m-source armv8m-*.o *.o
  make -j8 CROSS_FLAGS=-I$SCRIPT_DIR/libs/libc INC-armv8m="$YASOS_SYSINCLUDES"
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  PATH=$SCRIPT_DIR/libs/tinycc/bin:$PATH
  echo "Installing cross compiler..."
  make install INC-armv8m="$YASOS_SYSINCLUDES"
  if [ $? -ne 0 ]; then
    exit -1;
  fi

  # Verify cross-compiler was installed
  if [ ! -f "$SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc" ]; then
    echo "ERROR: Cross-compiler armv8m-tcc not found after install!"
    exit 1
  fi
  touch_stamp "$CROSS_STAMP_FILE"
  echo "Cross-compiler installed at: $SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc"

  cd ..
}

build_c_compiler()
{
  echo "Building C compiler..."
  cd tinycc
  mkdir -p bin
  PATH=$SCRIPT_DIR/libs/tinycc/bin:$PATH
  # gcc -o armv8m-tcc.o -c tcc.c -DTCC_TARGET_ARM -DTCC_ARM_VFP -DTCC_ARM_EABI -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_THUMB -DTCC_TARGET_ARM_ARCHV8M -DCONFIG_TCC_CROSSPREFIX="\"armv8m-\"" -I. -DTCC_GITHASH="\"2025-05-11 armv8m@ec701fe2*\"" -DTCC_DEBUG=2 -g -O0 -Wdeclaration-after-statement -Wno-unused-result

  # Use the workspace rootfs as sysroot to avoid linking against system newlib
  YASOS_SYSROOT="$SCRIPT_DIR/rootfs"
  YASOS_LIBPATHS="$SCRIPT_DIR/rootfs/usr/lib:{B}:$SCRIPT_DIR/rootfs/lib"
  YASOS_CRTPREFIX="$SCRIPT_DIR/rootfs/usr/lib"
  YASOS_SYSINCLUDES="$SCRIPT_DIR/rootfs/usr/include:{B}/include"

  NATIVE_TCC_DEBUG_CONFIG=""
  # -DCONFIG_TCC_DEBUG enables the on-target `-dump-ir` / `-dump-ir-passes=` flags
  # (libtcc.c gates them under #ifdef CONFIG_TCC_DEBUG) so the native compiler can
  # dump IR on-device for HW-vs-QEMU codegen comparison.
  # -DCONFIG_TCC_DEBUG_ENV=0 compiles out the ~30 getenv-driven debug/bisect
  # knobs (TCC_DISABLE_PASS, TCC_NO_COALESCE, DBG_CLINL, SCAN_OVERLAP, ...); see
  # libs/tinycc/tccdbgenv.h.  The device compiler is XIP-miss-bound, so the dead
  # trace blocks and verifiers cost flash and cache lines for nothing: dropping
  # them is .text -14,584 B / -17,272 B total, with byte-identical output.  The
  # HOST cross keeps them (the Makefile default follows CONFIG_TCC_DEBUG), so the
  # bisect tooling is unaffected.  --debug-tcc puts them back on-device.
  NATIVE_TCC_DEBUG_DEFINE="-DTCC_DEBUG=0 -DCONFIG_TCC_DEBUG -DCONFIG_TCC_DEBUG_ENV=0"
  NATIVE_TCC_DEBUG_OPT="${NATIVE_TCC_OPT_OVERRIDE:--O2}"
  if $DEBUG_TCC; then
    NATIVE_TCC_DEBUG_CONFIG="--debug --enable-O2"
    NATIVE_TCC_DEBUG_DEFINE="-DTCC_DEBUG=1 -DCONFIG_TCC_DEBUG -DCONFIG_TCC_DEBUG_ENV=1"
    NATIVE_TCC_DEBUG_OPT="-O2"
  elif $TCC_AB_KNOBS; then
    # Knobs only. TCC_DEBUG stays 0 and the -O level is untouched, so this
    # binary behaves like the release one and a fault reproduced here is the
    # same fault -- which is what makes the TCC_DISABLE_PASS bisect valid.
    NATIVE_TCC_DEBUG_DEFINE="-DTCC_DEBUG=0 -DCONFIG_TCC_DEBUG -DCONFIG_TCC_DEBUG_ENV=1"
  fi
  # The on-device compiler defaults to the same FPU as the cross compiler, so a
  # program compiled on the device matches the libraries it links against.
  # (Appended after the --debug-tcc branch, which replaces the string wholesale
  # and used to drop this.)
  NATIVE_TCC_DEBUG_DEFINE="$NATIVE_TCC_DEBUG_DEFINE $TCC_FP_DEFINE"

  NATIVE_STAGE1_OUTPUT="$SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc.elf"
  NATIVE_STAGE2_OUTPUT="$PREFIX/bin/tcc"
  NATIVE_STAGE1_STAMP_FILE="$TINYCC_STAMP_DIR/native-stage1.stamp"
  NATIVE_STAGE2_STAMP_FILE="$TINYCC_STAMP_DIR/native-stage2.stamp"
  SKIP_NATIVE_STAGE1=false
  SKIP_NATIVE_STAGE2=false

  if ! $CLEAR && [ -f "$NATIVE_STAGE1_STAMP_FILE" ] && [ -f "$NATIVE_STAGE1_OUTPUT" ] && ! tinycc_sources_newer_than "$NATIVE_STAGE1_STAMP_FILE"; then
    SKIP_NATIVE_STAGE1=true
  fi

  if ! $CLEAR && [ -f "$NATIVE_STAGE2_STAMP_FILE" ] && [ -f "$NATIVE_STAGE2_OUTPUT" ] && ! tinycc_sources_newer_than "$NATIVE_STAGE2_STAMP_FILE"; then
    SKIP_NATIVE_STAGE2=true
  fi

  # First stage: build with host paths to get working binary
  # Link against YasOS libraries, not host libraries.
  # The native armv8m bootstrap also needs the target runtime helpers archive explicitly.
  YASOS_LIBS="$SCRIPT_DIR/libs/tinycc/lib/tcc/armv8m-libtcc1.a -lpthread -ldl -lc -lm"
  if $SKIP_NATIVE_STAGE1; then
    echo "Native compiler stage 1 already up to date."
  else
    ./configure --cc=tcc --cpu=armv8m \
      --extra-cflags="-Wall -Werror $NATIVE_TCC_DEBUG_DEFINE $DEBUG_CFLAGS $NATIVE_TCC_DEBUG_OPT -DTCC_ARM_VFP -DTCC_ARM_EABI=1 -DCONFIG_TCC_BCHECK=0 -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTARGETOS_YasOS=1 -DTCC_TARGET_ARM_THUMB -DTCC_TARGET_ARM -DTCC_IS_NATIVE -I$PREFIX/include -fpie -fPIE -mcpu=cortex-m33 -fvisibility=hidden -ffunction-sections" \
      --extra-ldflags="-fpie -fPIE -fvisibility=hidden $DEBUG_CFLAGS -Wl,--gc-sections -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4 -DTCC_ARM_VFP -DTCC_TARGET_ARM -DTCC_ARM_EABI -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTCC_TARGET_ARM_THUMB -Wl,-oformat=elf32-littlearm" \
      --enable-cross --config-asm=yes --config-bcheck=no --config-pie=yes --config-pic=yes --config-ldl=no --config-pthread=no \
      --disable-asan \
      $NATIVE_TCC_DEBUG_CONFIG \
      --prefix="$SCRIPT_DIR/libs/tinycc" \
      --sysroot="$YASOS_SYSROOT" \
      --libpaths="$YASOS_LIBPATHS" \
      --crtprefix="$YASOS_CRTPREFIX" \
      --sysincludepaths="$YASOS_SYSINCLUDES" \
      --cross-prefix=armv8m-
    if [ $? -ne 0 ]; then
      exit -1;
    fi
    # The cross-compiler stage compiled the arch/ISA objects (armv8m-arch) and
    # the IR/core objects with the host gcc (x86).  The nested arch Makefile keys
    # recompilation on source timestamps only — not on the active CC or config.h —
    # so a plain `make armv8m-tcc` here re-archives those host objects into
    # armv8m-arch/arm/libarm.a, and the native armv8m-tcc link rejects them with
    # "invalid object file".  Drop all cross-stage build objects so the native
    # bootstrap recompiles everything with armv8m-tcc for the ARM target.
    # armv8m-source/ holds the relocated opt/backend objects (post source/opt
    # reorg) — dropping only armv8m-arch/armv8m-ir would reuse the other
    # stage's objects and fail the link with "unrecognized file type".
    rm -rf armv8m-arch armv8m-ir armv8m-source armv8m-*.o *.o
    # Archive the backend library with the host `ar`, not the cross-prefixed
    # `armv8m-tcc -ar`: the arch Makefile bundles libthumb.a into libarm.a via
    # ar's MRI batch mode (`ar -M`), which tcc's built-in archiver does not
    # support.  Archiving is target-agnostic, so the host ar handles the ARM
    # objects fine.
    VERBOSE=1 make armv8m-tcc -j8 AR=ar LIBS="$YASOS_LIBS" INC-armv8m="$YASOS_SYSINCLUDES"

    if [ $? -ne 0 ]; then
      exit -1;
    fi
    mv armv8m-tcc bin/armv8m-tcc.elf
    touch_stamp "$NATIVE_STAGE1_STAMP_FILE"

    if $CLEAR; then
      # Only force a fresh native tinycc reconfigure when explicitly requested.
      # Save the cross-compiler and FP libraries before distclean removes them.
      cp $SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc $SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc.saved
      mkdir -p /tmp/yasos-fp-libs-save
      cp $SCRIPT_DIR/libs/tinycc/lib/fp/lib*.{a,so} /tmp/yasos-fp-libs-save/ 2>/dev/null || true
      cp $SCRIPT_DIR/libs/tinycc/lib/fp/lib*.so.elf /tmp/yasos-fp-libs-save/ 2>/dev/null || true
      make distclean
      rm -f *.o armv8m-*.o
      # Restore the cross-compiler and FP libraries.
      mv $SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc.saved $SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc
      mkdir -p $SCRIPT_DIR/libs/tinycc/lib/fp
      cp /tmp/yasos-fp-libs-save/* $SCRIPT_DIR/libs/tinycc/lib/fp/ 2>/dev/null || true
      rm -rf /tmp/yasos-fp-libs-save
    fi
  fi

  # Second stage build with target prefix for correct embedded paths
  # Use target-relative paths for the native compiler
  NATIVE_LIBPATHS="/usr/lib:{B}:/lib"
  NATIVE_CRTPREFIX="/usr/lib"
  NATIVE_SYSINCLUDES="/usr/include:{B}/include"
  if $SKIP_NATIVE_STAGE2; then
    echo "Native compiler stage 2 already up to date."
  else
    ./configure --cc=tcc --cpu=armv8m \
      --extra-cflags="-Wall -Werror $NATIVE_TCC_DEBUG_DEFINE $DEBUG_CFLAGS $NATIVE_TCC_DEBUG_OPT -DTCC_ARM_VFP -DTCC_ARM_EABI=1 -DCONFIG_TCC_BCHECK=0 -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTARGETOS_YasOS=1 -DTCC_TARGET_ARM_THUMB -DTCC_TARGET_ARM -DTCC_IS_NATIVE -I$PREFIX/include -fpie -fPIE -mcpu=cortex-m33 -fvisibility=hidden -ffunction-sections" \
      --extra-ldflags="-fpie -fPIE -fvisibility=hidden $DEBUG_CFLAGS -Wl,--gc-sections -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4 -DTCC_ARM_VFP -DTCC_TARGET_ARM -DTCC_ARM_EABI -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTCC_TARGET_ARM_THUMB" \
      --enable-cross --config-asm=yes --config-bcheck=no --config-pie=yes --config-pic=yes --config-ldl=no --config-pthread=no \
      --disable-asan \
      $NATIVE_TCC_DEBUG_CONFIG \
      --prefix=/usr \
      --libpaths="$NATIVE_LIBPATHS" \
      --crtprefix="$NATIVE_CRTPREFIX" \
      --sysincludepaths="$NATIVE_SYSINCLUDES" \
      --cross-prefix=armv8m- \
      --sysroot=/
    if [ $? -ne 0 ]; then
      exit -1;
    fi
    # Compare critical config values between cross and native builds.
    # Differences in these defines cause PCH keyword/predefines mismatches.
    if [ -f config.h.cross ]; then
      echo "Comparing cross vs native config.h..."
      # Extract defines that affect keyword tables and predefines
      for def in CONFIG_TCC_BCHECK CONFIG_TCC_BACKTRACE CONFIG_TCC_PIE CONFIG_TCC_PIC CONFIG_TCC_PREDEFS; do
        cross_val=$(grep -o "#define $def [0-9]*" config.h.cross | head -1)
        native_val=$(grep -o "#define $def [0-9]*" config.h | head -1)
        if [ "$cross_val" != "$native_val" ]; then
          echo "WARNING: Config mismatch: cross='$cross_val' native='$native_val'"
        fi
      done
    fi
    # Use the host `ar` for the backend archive (MRI mode); see stage 1 above.
    VERBOSE=1 make armv8m-tcc -j8 AR=ar LIBS="$YASOS_LIBS" INC-armv8m="$NATIVE_SYSINCLUDES"
    if [ $? -ne 0 ]; then
      exit -1;
    fi
    # Copy the libtcc1.a files from cross-compiler install to build dir for make install
    cp $SCRIPT_DIR/libs/tinycc/lib/tcc/armv8m-libtcc1.a .
    make install armv8m-tcc DESTDIR=$SCRIPT_DIR/rootfs LIBS="$YASOS_LIBS" INC-armv8m="$NATIVE_SYSINCLUDES"
    if [ $? -ne 0 ]; then
      exit -1;
    fi
    mv $PREFIX/bin/armv8m-tcc $PREFIX/bin/tcc
    cp $PREFIX/lib/tcc/armv8m-libtcc1.a $PREFIX/lib/armv8m-libtcc1.a
    # Install FP libraries (shared .so for dynamic linking, .a for static)
    for fplib in $SCRIPT_DIR/libs/tinycc/lib/fp/libsoftfp.{a,so} \
                 $SCRIPT_DIR/libs/tinycc/lib/fp/libvfpv4sp.{a,so} \
                 $SCRIPT_DIR/libs/tinycc/lib/fp/libvfpv5dp.{a,so} \
                 $SCRIPT_DIR/libs/tinycc/lib/fp/librp2350fp.{a,so}; do
      if [ -f "$fplib" ]; then
        cp "$fplib" $PREFIX/lib/
        echo "Installed $(basename $fplib) to $PREFIX/lib/"
      fi
    done
    touch_stamp "$NATIVE_STAGE2_STAMP_FILE"
  fi
  cd ..
}

build_gnumake()
{
  cd $1
  if [ $CLEAR = true ]; then
    make clean
  fi
  LDFLAGS="-Wl,-oformat=elf32-littlearm" CFLAGS="$TARGET_BUILD_EXTRA_CFLAGS $DEBUG_CFLAGS" CC="$CC" ./configure --host=arm-none-eabi --prefix=$PREFIX
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  make
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  cp make make.elf
  CFLAGS="$TARGET_BUILD_EXTRA_CFLAGS $DEBUG_CFLAGS" CC="$CC" ./configure --host=arm-none-eabi --prefix=$PREFIX
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  make
  if [ $? -ne 0 ]; then
    exit -1;
  fi

  make install
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  cd ..
}

build_makefile()
{
  cd $1
  if [ $CLEAR = true ]; then
    make clean
  fi
  make CC="$CC" ROOTFS_OPT_CFLAGS="$TARGET_BUILD_EXTRA_CFLAGS" ROOTFS_DEBUG_CFLAGS="$DEBUG_CFLAGS" -j4
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  make CC="$CC" ROOTFS_OPT_CFLAGS="$TARGET_BUILD_EXTRA_CFLAGS" ROOTFS_DEBUG_CFLAGS="$DEBUG_CFLAGS" install PREFIX=$PREFIX
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  cd ..
}


build_zork_makefile()
{
  cd $1
  make CC="$CC" ROOTFS_OPT_CFLAGS="$TARGET_BUILD_EXTRA_CFLAGS" CFLAGS="$DEBUG_CFLAGS $TARGET_BUILD_EXTRA_CFLAGS -Wl,-oformat=elf32-littlearm" -j4
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  mv zork zork.elf

  make CC="$CC" ROOTFS_OPT_CFLAGS="$TARGET_BUILD_EXTRA_CFLAGS" ROOTFS_DEBUG_CFLAGS="$DEBUG_CFLAGS" -j4
  if [ $? -ne 0 ]; then
    exit -1;
  fi

  mkdir -p $PREFIX/games
  mkdir -p $PREFIX/games/lib

  make CC="$CC" ROOTFS_OPT_CFLAGS="$TARGET_BUILD_EXTRA_CFLAGS" ROOTFS_DEBUG_CFLAGS="$DEBUG_CFLAGS" install BINDIR=$PREFIX/games/ DATADIR=$PREFIX/games/lib/ MANDIR=$PREFIX/share/man/man6
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  mv $PREFIX/games/zork $PREFIX/games/hmm
  cd ..
}


build_cross_compiler

# ---- Stage 1: Build and install core libraries into rootfs ----
# The cross-compiler (armv8m-tcc) is configured to look for headers in
# rootfs/usr/include and libraries in rootfs/usr/lib + rootfs/lib.
# Libraries are built with -nostdlib/-nostdinc so they do not depend on
# a pre-existing libc.  Once installed, every subsequent compilation
# (including the target C compiler and all applications) will
# automatically pick them up from rootfs.

echo "Building libc..."
build_makefile libc

echo "Building libdl..."
build_makefile libdl

echo "Building libpthread..."
build_makefile pthread

echo "Building libm..."
build_makefile libm

echo "Building yasos_curses..."
build_makefile yasos_curses

echo "Building termcap..."
build_makefile termcap

# ---- Stage 2: Build the target (on-device) C compiler ----
# At this point rootfs/usr/lib contains libc.a, libdl.so, libpthread.so,
# etc., so the target tcc can link against them.

echo "Building target C compiler..."
build_c_compiler

if $DEBUG_TCC; then
  echo "TCC debug mode enabled. Native and cross compilers include CONFIG_TCC_DEBUG."
  echo "Use: tcc -dump-ir -c your_file.c"
  echo "Use: armv8m-tcc -dump-ir -c your_file.c"
fi

cd ..

cd apps

build_makefile coreutils
build_makefile cowsay
build_makefile ascii_animations
build_makefile textvaders
build_makefile hello_world
build_makefile hexdump
build_makefile yasvi
build_makefile mkfs
build_makefile longjump_tester
build_zork_makefile zork
build_makefile rzsz
build_makefile sha
build_makefile sdbench
build_makefile syscallbench
# build_gnumake make

TOYBOX_EXTRA_CFLAGS="$TARGET_BUILD_EXTRA_CFLAGS $DEBUG_CFLAGS" $SCRIPT_DIR/apps/toybox_builder/build.sh $PREFIX
if [ $? -ne 0 ]; then
  exit -1;
fi

cd ..

# ---- Stage 4: Precompile common headers for the native TCC ----
# Generate PCH files using the cross compiler.  The sysroot-stripping
# logic in tccpp.c ensures the stored paths match the target filesystem.
#
# The set of predefined macros depends on the optimization level
# (-O1 and up define __OPTIMIZE__, while -O0/-Os do not), and the PCH
# loader rejects a header whose predefine state differs from the current
# compile.  So we emit one PCH per predefine state: an unoptimized variant
# (foo.pch, matches -O0/-Os) and an optimized variant (foo.opt.pch, matches
# -O1/-O2/-O3).  Both are listed in auto.index against the same header; the
# loader silently picks whichever matches the current invocation.
PCH_DIR="$SCRIPT_DIR/rootfs/usr/lib/tcc/pch/armv8m"
if ! $GENERATE_PCH; then
  # Disabled to save flash on rp2350. Remove any stale PCH left in the tree by a
  # previous build so it does not get packed into the image (the loader silently
  # falls back to parsing the real headers when no auto.index is present).
  rm -rf "$SCRIPT_DIR/rootfs/usr/lib/tcc/pch"
  echo "Skipping precompiled headers (pass --with-pch to enable)"
else
mkdir -p "$PCH_DIR"
PCH_HEADERS="stdio.h stdlib.h string.h"
# "<opt-flags>:<pch-suffix>" — one entry per distinct predefine state.
PCH_VARIANTS=":  -O1:.opt"
PCH_INDEX=""
echo "Generating precompiled headers..."
for hdr in $PCH_HEADERS; do
  hdr_path="$SCRIPT_DIR/rootfs/usr/include/$hdr"
  if [ ! -f "$hdr_path" ]; then
    echo "  WARNING: Header $hdr_path not found, skipping PCH"
    continue
  fi
  for variant in $PCH_VARIANTS; do
    oflags="${variant%:*}"
    suffix="${variant#*:}"
    pch_name="${hdr%.h}${suffix}.pch"
    if armv8m-tcc $oflags -generate-pch "$hdr_path" -o "$PCH_DIR/$pch_name"; then
      PCH_INDEX="${PCH_INDEX}/usr/include/${hdr}\t${pch_name}\n"
      echo "  Generated $pch_name (${oflags:-unoptimized})"
    else
      echo "  WARNING: Failed to generate $pch_name"
    fi
  done
done
if [ -n "$PCH_INDEX" ]; then
  printf "$PCH_INDEX" > "$PCH_DIR/auto.index"
  echo "  Wrote auto.index"
fi

# Validate that generated PCH files can be loaded by the native compiler.
# The cross-compiler (armv8m-tcc) and native compiler share the same
# keyword table and predefines, so validating with the cross-compiler
# catches mismatches before flashing.  Each variant is validated at the
# optimization level it was generated for.
echo "Validating precompiled headers..."
PCH_VALID=true
for hdr in $PCH_HEADERS; do
  for variant in $PCH_VARIANTS; do
    oflags="${variant%:*}"
    suffix="${variant#*:}"
    pch_name="${hdr%.h}${suffix}.pch"
    pch_path="$PCH_DIR/$pch_name"
    if [ -f "$pch_path" ]; then
      # Create a minimal test file that includes the header
      echo "#include <$hdr>" > /tmp/pch_validate_$$.c
      echo "int main(void){return 0;}" >> /tmp/pch_validate_$$.c
      output=$(armv8m-tcc $oflags -verbose-pch -use-pch "$pch_path" -c /tmp/pch_validate_$$.c -o /dev/null 2>&1)
      if echo "$output" | grep -q "ignoring PCH"; then
        echo "  ERROR: PCH validation failed for $pch_name:"
        echo "$output" | grep -E "pch:|ignoring PCH" | sed 's/^/    /'
        PCH_VALID=false
      else
        echo "  Validated $pch_name OK (${oflags:-unoptimized})"
      fi
      rm -f /tmp/pch_validate_$$.c
    fi
  done
done
if ! $PCH_VALID; then
  echo "ERROR: PCH validation failed! Cross and native compilers produce incompatible precompiled headers."
  echo "Check keyword table, predefines, and config.h defines for mismatches."
  exit 1
fi
fi # GENERATE_PCH

if $BUILD_IMAGE; then
  echo "Outputing file to: $OUTPUT_FILE"
  rm -f rootfs/bin/armv8m-tcc
  rm -f rootfs/lib/libc.a
  rm -rf rootfs/usr/share
  genromfs -f $OUTPUT_FILE -d rootfs -V rootfs
fi

# Re-embed the freshly built rootfs image into the kernel. The kernel pulls the
# romfs in via `.incbin "<image>"`. build.zig already busts zig's assembly cache
# when the image changes (it hashes rootfs.img into the generated rootfs.S), so a
# plain `zig build` re-embeds the fresh image — the staleness people hit is simply
# forgetting to run `zig build` after regenerating rootfs.img. Do it here. Skip
# when no image was produced, when --no-kernel was passed (caller drives its own
# zig build, e.g. scripts/run_qemu_smoke.sh), when this target doesn't embed the
# image (no matching .incbin), or when the kernel hasn't been configured yet.
if $BUILD_IMAGE && $REBUILD_KERNEL; then
  IMG_BASE=$(basename "$OUTPUT_FILE")
  EMBEDS_IMG=$(grep -rlE "\.incbin[[:space:]]+\"$IMG_BASE\"" "$SCRIPT_DIR/hal" 2>/dev/null | head -1)
  KERNEL_CONFIG="$SCRIPT_DIR/config/target/config.json"
  if [ -z "$EMBEDS_IMG" ]; then
    echo "Kernel: no source .incbin's '$IMG_BASE' — not a romfs-embedded target, skipping kernel rebuild."
  elif [ ! -f "$KERNEL_CONFIG" ]; then
    echo "Kernel: not configured ($KERNEL_CONFIG missing). Run 'zig build defconfig -Ddefconfig_file=<cfg>' first; skipping kernel rebuild."
  elif ! command -v zig >/dev/null 2>&1; then
    echo "Kernel: zig not found in PATH; skipping kernel rebuild."
  else
    KERNEL_OPTIMIZE="${YASOS_KERNEL_OPTIMIZE:-${YASOS_QEMU_OPTIMIZE:-ReleaseFast}}"
    echo "Kernel: re-embedding $IMG_BASE and rebuilding (-Doptimize=$KERNEL_OPTIMIZE)..."
    if ! ( cd "$SCRIPT_DIR" && zig build -Doptimize="$KERNEL_OPTIMIZE" ); then
      echo "ERROR: kernel rebuild failed."
      exit 1
    fi
    echo "Kernel: rebuilt zig-out/bin/yasos_kernel with fresh romfs."
  fi
fi

# Record the floating point mode this tree was built with, last, so a run that
# died half-way leaves the previous value and the next run still forces the
# clean rebuild a mode change needs (see the FP_MODE block at the top).
mkdir -p "$TINYCC_STAMP_DIR"
echo "$FP_MODE" > "$FP_MODE_STAMP"
