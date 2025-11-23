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
  mkdir -p bin
  ./configure --extra-cflags="-DTCC_DEBUG=0 -g -O0 -DTARGETOS_YasOS=1 -Wall -Werror" --enable-cross --config-asm=yes --config-bcheck=no --config-pie=yes --config-pic=yes --prefix="$PREFIX" --sysroot="$SCRIPT_DIR/rootfs"
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  make -j8 CROSS_FLAGS=-I$SCRIPT_DIR/libs/libc
  PATH=$SCRIPT_DIR/libs/tinycc/bin:$PATH
  echo "Installing cross compiler..."
  make install

  cp armv8m-tcc bin
  cd ..
}

build_c_compiler()
{
  echo "Building C compiler..."
  cd tinycc
  mkdir -p bin
  PATH=$SCRIPT_DIR/libs/tinycc/bin:$PATH
  # gcc -o armv8m-tcc.o -c tcc.c -DTCC_TARGET_ARM -DTCC_ARM_VFP -DTCC_ARM_EABI -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_THUMB -DTCC_TARGET_ARM_ARCHV8M -DCONFIG_TCC_CROSSPREFIX="\"armv8m-\"" -I. -DTCC_GITHASH="\"2025-05-11 armv8m@ec701fe2*\"" -DTCC_DEBUG=2 -g -O0 -Wdeclaration-after-statement -Wno-unused-result

  ./configure --cc=tcc --cpu=armv8m -B=/ --extra-cflags="-Wall -Werror -DTCC_DEBUG=0 -g -O0 -DTCC_ARM_VFP  -DTCC_ARM_EABI=1 -DCONFIG_TCC_BCHECK=0 -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTARGETOS_YasOS=1 -DTCC_TARGET_ARM_THUMB -DTCC_TARGET_ARM -DTCC_IS_NATIVE -I$PREFIX/include -fpie -fPIE -mcpu=cortex-m33 -fvisibility=hidden -L../../rootfs/lib" --extra-ldflags="-fpie -fPIE -fvisiblity=hidden -g -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4   -DTCC_ARM_VFP -DTCC_TARGET_ARM  -DTCC_ARM_EABI -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTCC_TARGET_ARM_THUMB -Wl,-oformat=yaff" --enable-cross --config-asm=yes --config-bcheck=no --config-pie=yes --config-pic=yes --prefix="$PREFIX" --sysroot="/"  --sysincludepaths="/usr/include" --cross-prefix=armv8m-
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  VERBOSE=1 make armv8m-tcc -j8

  if [ $? -ne 0 ]; then
    exit -1;
  fi
  make install armv8m-tcc
  mv $PREFIX/bin/armv8m-tcc $PREFIX/bin/tcc.elf
  cp armv8m-libtcc1.a $PREFIX/lib
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
  if [ $CLEAR = true]; then
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
# build_gnumake make

$SCRIPT_DIR/apps/toybox_builder/build.sh $PREFIX

cd ..

if $BUILD_IMAGE; then
  echo "Outputing file to: $OUTPUT_FILE"
  rm -f rootfs/bin/armv8m-tcc
  rm -f rootfs/lib/libc.a
  rm -rf rootfs/usr/share
  rm -f rootfs/bin/tcc
  mv rootfs/bin/tcc.elf rootfs/bin/tcc
  genromfs -f $OUTPUT_FILE -d rootfs -V rootfs
fi

