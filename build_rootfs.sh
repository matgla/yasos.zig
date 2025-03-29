#!/bin/sh

OPTIONS=co:
LONGOPTIONS=clear,output:

PARSED=$(getopt --options $OPTIONS --longoptions $LONGOPTIONS --name "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    # If getopt has complained about anything, it will return a non-zero exit status
    exit 2
fi

eval set -- "$PARSED"

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

cd $SCRIPT_DIR

if $CLEAR; then 
  echo "Clearing..."
  rm -rf rootfs
  rm -rf apps/shell/build
  rm -rf libs/libc/build
  rm -rf libs/libdl/build
  rm -rf libs/pthread/build
fi
mkdir -p rootfs
mkdir -p rootfs/usr/include
mkdir -p rootfs/usr/lib
cd rootfs
ln -s usr/lib  
ln -s usr/bin
ls -lah
cd ..
mkdir -p rootfs/tmp
mkdir -p rootfs/dev

cd libs 

build_makefile()
{
  cd $1
  make CC=armv8m-tcc -j4
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  make install PREFIX=$PREFIX
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  cd ..
}

build_lib()
{
  cd $1
  mkdir -p build && cd build
  cmake .. -DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/libs/cmake/tcc_cortex_m33.cmake -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=$PREFIX
  cmake --build . --config Debug 
  if [ $? -ne 0 ]; then
    exit -1;
  fi
  cmake --install .
  if [ $? -ne 0 ]; then
    exit -1;
  fi
 
  cd ..
  cd ..
}

build_exec()
{
  cd $1
  mkdir -p build && cd build
  cmake .. -DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/apps/cmake/tcc_cortex_m33.cmake -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=$PREFIX
  cmake --build . --config Debug 
  if [ $? -ne 0 ]; then
    exit -1;
  fi
 
  cmake --install .
  if [ $? -ne 0 ]; then
    exit -1;
  fi
 
  cd ..
  cd ..
}

build_makefile libc
build_lib libdl
build_lib pthread

cd ..

cd apps

build_exec shell

cd ..

if $BUILD_IMAGE; then
  echo "Outputing file to: $OUTPUT_FILE"

  rm -rf /tmp/rootfs_temp 
  cp -r rootfs /tmp/rootfs_temp
  cd /tmp/rootfs_temp
  for file in **/*.so
  do
    if [ -f "$file" ]; then  # Check if it's a file
      mv $file $file.bak
      $SCRIPT_DIR/dynamic_loader/elftoyaff/mkimage/mkimage.py -i $file.bak --type shared_library -o $file
      rm $file.bak 
    fi
  done

  for file in **/*.elf
  do
    if [ -f "$file" ]; then  # Check if it's a file
      $SCRIPT_DIR/dynamic_loader/elftoyaff/mkimage/mkimage.py -i $file --type shared_library -o $(dirname $file)/$(basename "$file" .elf) --verbose
      rm $file 
    fi
  done
  cd ..

  genromfs -f $OUTPUT_FILE -d rootfs_temp -V rootfs 
  cp rootfs.img $SCRIPT_DIR
fi
