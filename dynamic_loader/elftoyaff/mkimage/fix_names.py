#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# fix_names.py
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
import subprocess
import os
from pathlib import Path

from elf_parser import ElfParser

print("Fixing symbols visibility and names in public functions:")

parser = argparse.ArgumentParser(
    description="""
                Wrappers generator for Yasiff modules
                """
)

parser.add_argument("-i", "--input", action="store", help="File to be processed")
parser.add_argument(
    "-c", "--objcopy", action="store", help="Path to objcopy executable"
)

args, _ = parser.parse_known_args()

symbols = []
parser = ElfParser(args.input)
for name, data in parser.symbols.items():
    if name.endswith("_yasld_wrapper"):
        symbols.append(name)

redefine_command = args.objcopy
for symbol in symbols:
    original_name = symbol.removesuffix("_yasld_wrapper")
    redefine_command += (
        " --redefine-sym " + original_name + "=" + original_name + "_yasld_original"
    )

redefine_command += " " + args.input + " " + args.input
print(redefine_command)
subprocess.run(redefine_command, capture_output=True, shell=True)

redefine_command = args.objcopy
for symbol in symbols:
    original_name = symbol.removesuffix("_yasld_wrapper")
    redefine_command += " --localize-symbol " + original_name + "_yasld_original"

redefine_command += " " + args.input + " " + args.input
print(redefine_command)
subprocess.run(redefine_command, capture_output=True, shell=True)

redefine_command = args.objcopy
for symbol in symbols:
    original_name = symbol.removesuffix("_yasld_wrapper")
    redefine_command += (
        " --redefine-sym " + original_name + "_yasld_wrapper" + "=" + original_name
    )

redefine_command += " " + args.input + " " + args.input
print(redefine_command)
subprocess.run(redefine_command, capture_output=True, shell=True)
