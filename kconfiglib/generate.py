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
import sys
import os
import json

from kconfiglib import Kconfig, Symbol, Choice, MENU, COMMENT

parser = argparse.ArgumentParser(description = "CMake configuration generator based on KConfig")
parser.add_argument("-i", "--input", dest="input_file", action="store", help="Path to input file", required=True)
parser.add_argument("-o", "--output", dest="output_directory", action="store", help="Path to output directory", required=True)
parser.add_argument("-k", "--kconfig", dest="kconfig", action="store", help="Path to kconfig file", required=True)

args, rest = parser.parse_known_args()

to_parse = []

def process_symbol(symbol, value):
    obj = {}
    current_obj = obj
    for part in symbol:
        if part.startswith("KEY$"):
            pass
        elif part.endswith("$ARRAY"):
            part = part.replace("$ARRAY", "")
            current_obj[part.lower()] = []
            current_obj = current_obj[part.lower()]
        elif part.find("$") != -1:
            part = part.split('$')
            part = [i for i in part if i]
            key = part[0].lower()
            val = None
            if len(part) == 1:
                val = value.lower()
            else:
                val = part[1].lower()

            if isinstance(current_obj, dict):
                current_obj.update({key: val})
            else:
                current_obj.append({key: val})
                current_obj = current_obj[-1]

        else:
            if isinstance(current_obj, dict):
                current_obj[part.lower()] = {}
                current_obj = current_obj[part.lower()]
            else:
                current_obj.append({})

    return obj


def merge(old, new):
    for k in new:
        if k in old:
            if isinstance(old[k], dict):
                merge(old[k], new[k])
            if isinstance(old[k], list):
                old[k] = old[k] + new[k]
            else:
                old[k] = new[k]
        else:
            old[k] = new[k]

    return old


def generate_json():
    config = {}
    for entity in to_parse:
        splitted_name = entity["name"].split('.')
        if splitted_name[0] == "PARAM":
            pass
        if splitted_name[0] == "PARAM_ARRAY":
            obj = process_symbol(splitted_name[1:], entity["value"])
            merge(config, obj)

    return config

def main():
    print ("Kconfig generator started")
    kconf = Kconfig(args.kconfig)
    kconf.load_config(args.input_file)
    if not os.path.exists(args.output_directory):
        os.makedirs(args.output_directory)

    with open(args.output_directory + "/config.cmake", "w") as output:
        for node in kconf.unique_defined_syms:
            if node.user_value:
                to_parse.append({"name": node.name, "value": node.user_value})
                output.write("set(" + node.name + " " + str(node.user_value) + ")\n")
                continue
            if node.str_value:
                to_parse.append({"name": node.name, "value": node.str_value})

    config = generate_json()
    with open(args.output_directory + "/config.json", "w") as output:
        output.write(json.dumps(config))

main()
