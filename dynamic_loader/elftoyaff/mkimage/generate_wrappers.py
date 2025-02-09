#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# generate_wrappers.py
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
import jinja2
import os
import sys

from pathlib import Path

from elf_parser import ElfParser

print("Generating wrappers for public functions:")

parser = argparse.ArgumentParser(
    description="""
                Wrappers generator for Yasiff modules
                """
)

parser.add_argument(
    "-i", "--input", action="store", help="List of files separated by ',' or ';'"
)
parser.add_argument(
    "-o", "--output", action="store", help="Generated file with wrappers"
)
parser.add_argument(
    "-c", "--objcopy", action="store", help="Path to objcopy executable"
)
parser.add_argument(
    "-t", "--template", action="store", help="Path to templates directory"
)
parser.add_argument("-b", "--compiler", action="store", help="Compile command")
parser.add_argument("-f", "--compiler_flags", action="store", help="Compile flags")
parser.add_argument("-a", "--ar", action="store", help="Compile command")


args, _ = parser.parse_known_args()

print(args.compiler)
print(args.compiler_flags)
files = args.input.replace(",", ";").split(";")

templates = Path(args.template)
print("Template path is: ", templates)
env = jinja2.Environment(loader=jinja2.FileSystemLoader(templates))
template = env.get_template("call_wrapped.s.tmpl")

generated_file = ""
for file in files:
    symbols = []
    print("File: ", file)
    wrapped_symbols = []
    parser = ElfParser(file)
    for name, data in parser.symbols.items():
        if name.endswith("_yasld_original"):
            wrapped_symbols.append(
                name.removeprefix("__").removesuffix("_yasld_original")
            )
            continue
        is_global_and_visible = (
            data["binding"] == "STB_GLOBAL" and data["visibility"] != "STV_HIDDEN"
        )
        if is_global_and_visible and data["type"] == "STT_FUNC":
            symbols.append(name)
            wrapped_symbols.append(name)

    generated_file += template.render(names=wrapped_symbols)

if os.path.exists(args.output):
    os.remove(args.output)

with open(args.output, "x") as file:
    file.write(generated_file)

command = (
    args.compiler
    + " "
    + args.compiler_flags
    + " -c "
    + args.output
    + " -o "
    + args.output
    + ".obj"
)
print("Generate file with command: ", command)
output = subprocess.run(command, shell=True, capture_output=True)
print(output.stdout)
print(output.stderr)
if output.returncode != 0:
    sys.exit(output.returncode)


command = (
    args.ar + " rcs lib" + args.output.split(".")[0] + ".a" + " " + args.output + ".obj"
)

print("Generate file with command: ", command)
output = subprocess.run(command, shell=True, capture_output=True)


print(output.stdout)
print(output.stderr)
if output.returncode != 0:
    sys.exit(output.returncode)
