#!/bin/sh 

cd "$(dirname "$0")"
pwd
cp yasos.config ../toybox/.config
cd ../toybox  
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="-I$1/usr/include -g" LDFLAGS="-Wl,-oformat=elf32-littlearm" make toybox
mv -f ../toybox/toybox ../toybox/toybox.elf
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="-I$1/usr/include -g" make toybox
# PREFIX=$1 CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t make install
cp ../toybox/toybox $1/bin/toybox

