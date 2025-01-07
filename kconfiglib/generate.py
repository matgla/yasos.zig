#!/usr/bin/python3

# This file is part of Yasboot project.
# Copyright (C) 2023 Mateusz Stadnik
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

import argparse
import os
from pathlib import Path

from kconfiglib import Kconfig, MENU, COMMENT

parser = argparse.ArgumentParser(description = "CMake configuration generator based on KConfig")
parser.add_argument("-i", "--input", dest="input_file", action="store", help="Path to input file", required=True)
parser.add_argument("-o", "--output", dest="output_file", action="store", help="Path to output directory", required=True)
parser.add_argument("-k", "--kconfig", dest="kconfig", action="store", help="Path to kconfig file", required=True)

args, rest = parser.parse_known_args()

def main():
    print ("Kconfig generator started")
    kconf = Kconfig(args.kconfig)
    kconf.load_config(args.input_file)
    if not os.path.exists(Path(args.output_file).parent):
        os.makedirs(Path(args.output_file).parent)

    to_file = []
    print ("Writing configuration file to:", args.output_file)
    with open(args.output_file, "w") as output:
        output.write("{\n")
        for node in kconf.unique_defined_syms:
            if node.user_value:
                #output.write("  \"" + node.name.lower() + "\": \"" + str(node.user_value) + "\",\n")
                to_file.append({"name": node.name.lower(), "value": str(node.user_value)}) 
                continue
        for i in range(0, len(to_file) - 1):
            output.write("  \"" + to_file[i]["name"] + "\": \"" + to_file[i]["value"] + "\",\n")
        output.write("  \"" + to_file[-1]["name"] + "\": \"" + to_file[-1]["value"] + "\"\n")
        output.write("}\n")

main()
