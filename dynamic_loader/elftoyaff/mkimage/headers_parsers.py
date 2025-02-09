#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# headers_parsers.py
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


import CppHeaderParser

import argparse
import subprocess
import re

parser = argparse.ArgumentParser()
parser.add_argument("-i", "--input", required=True)

args, _ = parser.parse_known_args()


def get_mangled_symbol(declaration):
    command = "echo -e '{decl}' | g++ -x c++ -S - -o-".format(decl=declaration + "{}")

    mangled_name = str(
        subprocess.run(command, shell=True, capture_output=True).stdout,
        encoding="utf-8",
    )

    mangled_name = (
        re.findall(".type.*", mangled_name, re.MULTILINE)[0]
        .split()[1]
        .removesuffix(",")
    )

    return mangled_name


def build_method_declaration():
    pass


symbols = {}

h = CppHeaderParser.CppHeader(args.input)

print(h.includes)


def build_functions_symbol_table():
    for f in h.functions:
        args = ""
        for p in f["parameters"]:
            args += p["type"] + " " + p["name"] + ","

        args = args.removesuffix(",")

        declaration = "{ret} {name}({args})".format(
            name=f["name"], ret=f["rtnType"], args=args
        )

        print(f)


def build_class_symbol_table():
    for name in h.classes:
        for method in h.classes[name].get_all_methods():
            print(method["name"])


build_functions_symbol_table()
build_class_symbol_table()

print(symbols)
