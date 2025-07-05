#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# parse_mbr.py
#
# Copyright (C) 2023 Mateusz Stadnik <matgla@live.com>
#
# This program is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation, either version
# 3 of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
# PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General
# Public License along with this program. If not, see
# <https://www.gnu.org/licenses/>.
#

import argparse 
import pymbr

parser = argparse.ArgumentParser(description = "Tool to write Yasboot to MBR drive")

parser.add_argument("--drive", "-d", dest="drive", action="store", help="Drive to flash bootloader", required=True)
parser.add_argument("--yasboot", "-y", dest="yasboot", action="store", help="Yasboot image to write")
parser.add_argument("--bootcode", "-b", dest="bootcode", action="store", help="Bootcode image to write")


def find_first_partition(mbr):
    partition_table = mbr.partitionTable.partitions.items()

    # filter out empty partitions
    partition_table = filter(lambda p : (p[1].realSize() != 0), partition_table)
    return min(partition_table, key=lambda p : (p[1].lba and (p[1].realSize() != 0)))

def validate(mbr):
   mbr.partitionTable.validate()

# Returns size of empty space between MBR and first partition
def getEmptySpace(partition):
    return (partition.lba - 1) * 512

def main():
    args, rest = parser.parse_known_args()
    
    if not args.yasboot:
        args.yasboot = "yasboot.bin"

    if not args.bootcode:
        args.bootcode = "boot.bin"
 
    drive = None 
    with open(args.drive, "rb") as file:
        drive = file.read()

    mbr = pymbr.MBR.parse(drive[0:512])
    validate(mbr)
    
    # verify that yasboot fits in space between MBR end and first partition
    first_partition_index, first_partition = find_first_partition(mbr) 
    free_space = getEmptySpace(first_partition) 
    print("Free space for bootloader: ", free_space)

    yasboot = None
    with open(args.yasboot, "rb") as file:
        yasboot = file.read()

    if (len(yasboot) > free_space):
        raise RuntimeError("Not enough space for bootloader, needed at least: " + str(len(yasboot)) + " bytes")

    bootcode = None
    with open(args.bootcode, "rb") as file:
        bootcode = file.read()

    mbr.bootcode = bootcode 

    mbr_bin = mbr.compose() 
    mbr_bin = mbr_bin + yasboot 
    mbr_bin = mbr_bin + bytes(free_space - len(yasboot))
    mbr_bin = mbr_bin + drive[free_space + 512 : ]
    with open(args.drive, "wb") as file:
        file.write(mbr_bin)
        print ("Yasboot successfuly installed on drive: ", args.drive)
        print ("Empty space left: ", free_space - len(yasboot), " bytes")

if __name__ == "__main__":
    main()
