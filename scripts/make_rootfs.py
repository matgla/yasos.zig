#!/bin/python3
#
# make_rootfs.zig
#
# Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
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

import os 
import argparse
import subprocess
from pathlib import Path 

parser = argparse.ArgumentParser()
parser.add_argument("-o", "--output", help="Output file with rootfs image", required=True)
parser.add_argument("-w", "--workdir", help="Working directory to create filesystem tree", required=True)

args, _ = parser.parse_known_args()

print ("  Creating rootfs:", args.output)
print ("Working directory:", args.workdir)

cwd = os.getcwd()

def create_filesystem():
    os.makedirs(args.workdir, exist_ok=True)
    os.chdir(args.workdir)
    os.makedirs("bin", exist_ok=True)
    os.makedirs("etc", exist_ok=True)
    os.makedirs("sbin", exist_ok=True)
    os.makedirs("usr", exist_ok=True)
    os.makedirs("var", exist_ok=True)
    os.makedirs("dev", exist_ok=True)
    os.makedirs("home", exist_ok=True)
    os.makedirs("lib", exist_ok=True)
    os.makedirs("mnt", exist_ok=True)
    os.makedirs("opt", exist_ok=True)
    os.makedirs("proc", exist_ok=True)
    os.makedirs("root", exist_ok=True)

script_dir = Path(__file__).parent

def prepare_genromfs():
    subprocess.run(["make", "genromfs"], cwd=script_dir.parent / "libs" / "genromfs")

def build_image():
    subprocess.run(["./genromfs", "-d", args.workdir, "-V", "rootfs", "-f", cwd + "/" + args.output], cwd=script_dir.parent / "libs" / "genromfs")



create_filesystem()
prepare_genromfs()
build_image()