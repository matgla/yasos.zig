#!/bin/sh

OPTIONS=c
LONGOPTIONS=clear

PARSED=$(getopt --options $OPTIONS --longoptions $LONGOPTIONS --name "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    # If getopt has complained about anything, it will return a non-zero exit status
    exit 2
fi

eval set -- "$PARSED"

# Default value
CLEAR=false

# Process the options
while true; do
    case "$1" in
        -c|--clear)
            CLEAR=true
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
cd $SCRIPT_DIR

if $CLEAR; then 
  echo "Clearing..."
  rm -rf rootfs
  rm -rf libs/libc/build
  rm -rf libs/libdl/build
  rm -rf libs/pthread/build
fi
mkdir -p rootfs
mkdir -p rootfs/lib
mkdir -p rootfs/usr/include

cd libs 

build_lib()
{
  cd $1
  mkdir -p build && cd build
  cmake .. -DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/libs/cmake/cortex_m33.cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$SCRIPT_DIR/rootfs
  cmake --build . --config Release
  cmake --install .
  cd ..
  cd ..
}

build_lib libc
build_lib libdl
build_lib pthread
