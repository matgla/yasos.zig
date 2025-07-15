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
current_dump = 0
for line in encoded_dump_lines:
    line = line.strip()
    match = re.search(r"0x", line)
    if match: 
        index = match.start()
        line_number = line[0:index].split()[1][:-1]
        if int(line_number) == 0:
            dumps.append([])
        dumps[-1].append(line[index:])
    else:
        continue

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
        


