#!/bin/bash

if [[ "$(uname)" == "Darwin" ]]; then
GETOPT_CMD="/opt/homebrew/Cellar/gnu-getopt/2.41/bin/getopt"
else
GETOPT_CMD="/usr/bin/getopt"
fi
OPTIONS=co:
LONGOPTIONS=clear,output:

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

  rm -rf libs/tinycc/bin
  cd libs/tinycc && make clean && cd ../..
  cd apps/zork && make clean && cd ../..
fi
mkdir -p rootfs
mkdir -p rootfs/usr/include
mkdir -p rootfs/usr/lib
mkdir -p rootfs/proc
mkdir -p rootfs/root
mkdir -p rootfs/home
cd rootfs
ln -s usr/lib
ln -s usr/bin
ls -lah
pwd
cd ..
mkdir -p rootfs/tmp
cp $SCRIPT_DIR/hello_world.c rootfs/usr
cp $SCRIPT_DIR/hello_script.sh rootfs/usr

mkdir -p rootfs/dev
pwd
cd libs

build_cross_compiler()
{
  echo "Building cross compiler..."
  cd tinycc
  # Clean any stale configs from previous builds
  make distclean 2>/dev/null || true
  rm -f config.h config.mak *.o
  mkdir -p bin
  # Use explicit workspace paths to avoid system newlib
  YASOS_SYSROOT="$SCRIPT_DIR/rootfs"
  YASOS_LIBPATHS="{B}:$SCRIPT_DIR/rootfs/usr/lib:$SCRIPT_DIR/rootfs/lib"
  YASOS_CRTPREFIX="$SCRIPT_DIR/rootfs/usr/lib"
  YASOS_SYSINCLUDES="{B}/include:$SCRIPT_DIR/rootfs/usr/include"

  ./configure --extra-cflags="-DTCC_DEBUG=0 -g -O0 -DTARGETOS_YasOS=1 -Wall -Werror" \
    --enable-cross --config-asm=yes --config-bcheck=no --config-pie=yes --config-pic=yes \
    --prefix="$SCRIPT_DIR/libs/tinycc" \
    --sysroot="$YASOS_SYSROOT" \
    --libpaths="$YASOS_LIBPATHS" \
    --crtprefix="$YASOS_CRTPREFIX" \
    --sysincludepaths="$YASOS_SYSINCLUDES"
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  make -j8 CROSS_FLAGS=-I$SCRIPT_DIR/libs/libc
  PATH=$SCRIPT_DIR/libs/tinycc/bin:$PATH
  echo "Installing cross compiler..."
  make install

  # Verify cross-compiler was installed
  if [ ! -f "$SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc" ]; then
    echo "ERROR: Cross-compiler armv8m-tcc not found after install!"
    exit 1
  fi
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
  YASOS_LIBPATHS="{B}:$SCRIPT_DIR/rootfs/usr/lib:$SCRIPT_DIR/rootfs/lib"
  YASOS_CRTPREFIX="$SCRIPT_DIR/rootfs/usr/lib"
  YASOS_SYSINCLUDES="{B}/include:$SCRIPT_DIR/rootfs/usr/include"

  # First stage: build with host paths to get working binary
  ./configure --cc=tcc --cpu=armv8m \
    --extra-cflags="-Wall -Werror -DTCC_DEBUG=0 -g -O1 -DTCC_ARM_VFP -DTCC_ARM_EABI=1 -DCONFIG_TCC_BCHECK=0 -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTARGETOS_YasOS=1 -DTCC_TARGET_ARM_THUMB -DTCC_TARGET_ARM -DTCC_IS_NATIVE -I$PREFIX/include -fpie -fPIE -mcpu=cortex-m33 -fvisibility=hidden" \
    --extra-ldflags="-fpie -fPIE -fvisibility=hidden -g -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4 -DTCC_ARM_VFP -DTCC_TARGET_ARM -DTCC_ARM_EABI -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTCC_TARGET_ARM_THUMB -Wl,-oformat=elf32-littlearm" \
    --enable-cross --config-asm=yes --config-bcheck=no --config-pie=yes --config-pic=yes --config-ldl=no --config-pthread=no \
    --prefix="$SCRIPT_DIR/libs/tinycc" \
    --sysroot="$YASOS_SYSROOT" \
    --libpaths="$YASOS_LIBPATHS" \
    --crtprefix="$YASOS_CRTPREFIX" \
    --sysincludepaths="$YASOS_SYSINCLUDES" \
    --cross-prefix=armv8m-
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  # Link against YasOS libraries, not host libraries
  # libtcc1.a is added automatically by tcc, but we need libc/libm for tcc's own code
  YASOS_LIBS="-lpthread -ldl -lc -lm"
  VERBOSE=1 make armv8m-tcc -j8 LIBS="$YASOS_LIBS"

  if [ $? -ne 0 ]; then
    exit -1;
  fi
  mv armv8m-tcc bin/armv8m-tcc.elf
  # Save the cross-compiler and FP libraries before distclean removes them
  cp $SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc $SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc.saved
  mkdir -p /tmp/yasos-fp-libs-save
  cp $SCRIPT_DIR/libs/tinycc/lib/fp/lib*.{a,so} /tmp/yasos-fp-libs-save/ 2>/dev/null || true
  make distclean
  rm -f *.o armv8m-*.o
  # Restore the cross-compiler and FP libraries
  mv $SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc.saved $SCRIPT_DIR/libs/tinycc/bin/armv8m-tcc
  mkdir -p $SCRIPT_DIR/libs/tinycc/lib/fp
  cp /tmp/yasos-fp-libs-save/* $SCRIPT_DIR/libs/tinycc/lib/fp/ 2>/dev/null || true
  rm -rf /tmp/yasos-fp-libs-save

  # Second stage build with target prefix for correct embedded paths
  # Use target-relative paths for the native compiler
  NATIVE_LIBPATHS="{B}:/usr/lib:/lib"
  NATIVE_CRTPREFIX="/usr/lib"
  NATIVE_SYSINCLUDES="{B}/include:/usr/include"
  ./configure --cc=tcc --cpu=armv8m \
    --extra-cflags="-Wall -Werror -DTCC_DEBUG=0 -g -O1 -DTCC_ARM_VFP -DTCC_ARM_EABI=1 -DCONFIG_TCC_BCHECK=0 -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTARGETOS_YasOS=1 -DTCC_TARGET_ARM_THUMB -DTCC_TARGET_ARM -DTCC_IS_NATIVE -I$PREFIX/include -fpie -fPIE -mcpu=cortex-m33 -fvisibility=hidden" \
    --extra-ldflags="-fpie -fPIE -fvisibility=hidden -g -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4 -DTCC_ARM_VFP -DTCC_TARGET_ARM -DTCC_ARM_EABI -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTCC_TARGET_ARM_THUMB" \
    --enable-cross --config-asm=yes --config-bcheck=no --config-pie=yes --config-pic=yes --config-ldl=no --config-pthread=no \
    --prefix=/usr \
    --libpaths="$NATIVE_LIBPATHS" \
    --crtprefix="$NATIVE_CRTPREFIX" \
    --sysincludepaths="$NATIVE_SYSINCLUDES" \
    --cross-prefix=armv8m- \
    --sysroot=/
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  VERBOSE=1 make armv8m-tcc -j8 LIBS="$YASOS_LIBS"
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  # Copy the libtcc1.a files from cross-compiler install to build dir for make install
  cp $SCRIPT_DIR/libs/tinycc/lib/tcc/armv8m-libtcc1.a .
  make install armv8m-tcc DESTDIR=$SCRIPT_DIR/rootfs LIBS="$YASOS_LIBS"
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
  cd ..
}

build_gnumake()
{
  cd $1
  if [ $CLEAR = true ]; then
    make clean
  fi
  LDFLAGS="-Wl,-oformat=elf32-littlearm" CC=$CC ./configure --host=arm-none-eabi --prefix=$PREFIX
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  make
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  cp make make.elf
  CC=$CC ./configure --host=arm-none-eabi --prefix=$PREFIX
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
  make CC=$CC -j4
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  make CC=$CC install PREFIX=$PREFIX
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  cd ..
}


build_zork_makefile()
{
  cd $1
  make CC=$CC CFLAGS="-g -Wl,-oformat=elf32-littlearm" -j4
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  mv zork zork.elf

  make CC=$CC -j4
  if [ $? -ne 0 ]; then
    exit -1;
  fi

  mkdir -p $PREFIX/games
  mkdir -p $PREFIX/games/lib

  make CC=$CC install BINDIR=$PREFIX/games/ DATADIR=$PREFIX/games/lib/ MANDIR=$PREFIX/share/man/man6
  mv $PREFIX/games/zork $PREFIX/games/hmm
  if [ $? -ne 0 ]; then
    exit -1;
  fi
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

echo "Building yasos_curses..."
build_makefile yasos_curses

echo "Building libm..."
build_makefile libm

echo "Building termcap..."
build_makefile termcap

# ---- Stage 2: Build the target (on-device) C compiler ----
# At this point rootfs/usr/lib contains libc.a, libdl.so, libpthread.so,
# etc., so the target tcc can link against them.

echo "Building target C compiler..."
build_c_compiler

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
# build_gnumake make

$SCRIPT_DIR/apps/toybox_builder/build.sh $PREFIX

cd ..

if $BUILD_IMAGE; then
  echo "Outputing file to: $OUTPUT_FILE"
  rm -f rootfs/bin/armv8m-tcc
  rm -f rootfs/lib/libc.a
  rm -rf rootfs/usr/share
  genromfs -f $OUTPUT_FILE -d rootfs -V rootfs
fi

