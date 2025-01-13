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
import sys
from pathlib import Path
import json

from kconfiglib import Kconfig, MENU, COMMENT, BOOL, STRING, TRISTATE, INT, HEX, UNKNOWN

parser = argparse.ArgumentParser(
    description="CMake configuration generator based on KConfig"
)
parser.add_argument(
    "-i",
    "--input",
    dest="input_file",
    action="store",
    help="Path to input file",
    required=True,
)
parser.add_argument(
    "-o",
    "--output",
    dest="output",
    action="store",
    help="Path to output directory",
    required=True,
)
parser.add_argument(
    "-k",
    "--kconfig",
    dest="kconfig",
    action="store",
    help="Path to kconfig file",
    required=True,
)

args, rest = parser.parse_known_args()


def convert(value):
    if type(value) is bool:
        return "true" if value else "false"
    elif type(value) is str:
        return '"' + value + '"'
    else:
        raise RuntimeError("Unknown type: " + str(type(value)))


def main():
    print("Kconfig generator started")
    kconf = Kconfig(args.kconfig)
    kconf.load_config(args.input_file)
    if not os.path.exists(Path(args.output)):
        os.makedirs(Path(args.output))

    print("Writing configuration files to:", args.output)

    config = {}
    with open(args.output + "/config.json", "w") as output:
        for node in kconf.unique_defined_syms:
            if node.name is None:
                continue

            if not node.name.lower().startswith("config_"):
                continue

            name = node.name.lower().replace("config_", "")
            if node.str_value:
                if node.type == BOOL:
                    config[name] = node.str_value == "y"
                elif node.type == STRING:
                    config[name] = node.str_value
                elif node.type == TRISTATE:
                    raise RuntimeError("Tristate support not added")
                elif node.type == INT:
                    config[name] = str(node.str_value)
                elif node.type == HEX:
                    config[name] = str(node.str_value)
                elif node.type == UNKNOWN:
                    raise RuntimeError("Node: " + node.name + " -> has unknown type")
                else:
                    print(
                        "Can't handle type: "
                        + str(node.type)
                        + ", for node: "
                        + node.name
                        + ", please update me!"
                    )
                    sys.exit(-1)
                continue

        output.write(json.dumps(config))

    with open(args.output + "/config.zig", "w") as output:
        output.write("// This file was automatically generated, do not modify\n")

        started = False
        section = ""

        for field in sorted(config.items()):
            if field[0].lower().endswith("_discard_in_conf"):
                continue
            splitted_field = field[0].split("_")
            key = splitted_field[0]
            if section != key:
                # this is new section
                section = key
                if started:
                    output.write("};\n\n")
                output.write("const " + section + " = struct {\n")
                started = True
            field_key = field[0].replace(key + "_", "")
            output.write("  const " + field_key + " = " + convert(field[1]) + ";\n")

        if started:
            output.write("};\n\n")


main()
