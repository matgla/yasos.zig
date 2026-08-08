#!/usr/bin/python3

"""
 Copyright (c) 2025 Mateusz Stadnik

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 """

import argparse 
import re
import subprocess 

parse = argparse.ArgumentParser()
parse.add_argument("--input", "-i", help="Dump file", required=True)
parse.add_argument("--target", "-t", help="Path to symbols file (executable/shared library in ELF)", required=True)

args, _ = parse.parse_known_args()

print("Parsing core dump from:", args.input)
print("Parsing ELF file:", args.target)

encoded_dump_lines = None
with open(args.input, "r") as dump:
    encoded_dump_lines = dump.readlines()
  
dumps = []
for line in encoded_dump_lines:
    line = line.strip()
    # Match lines with format: "[prefix] N: 0xADDRESS" (stack trace entries)
    # where N is a line number (0, 1, 2, etc.)
    match = re.search(r"(\d+):\s+(0x[0-9a-fA-F]+)", line)
    if match:
        line_number = int(match.group(1))
        address = match.group(2)
        if line_number == 0:
            dumps.append([])
        if dumps:  # Only append if we have an active dump
            dumps[-1].append(address)

for dump_lines in dumps:
    print("===========================================")
    for line in dump_lines:
        result = subprocess.run(["addr2line", "-e", args.target, line], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode == 0:
            print(result.stdout.strip())
            decoding = result.stdout.split(":")
            try: 
                with open(decoding[0], "r") as source_file:
                    filelines = source_file.readlines()
                    print("  ", filelines[int(decoding[1]) - 1].strip(), "\n")
            except:
                continue 
    print("============================================")
        


