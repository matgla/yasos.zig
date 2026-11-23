#!/usr/bin/env python3
"""
 Copyright (c) 2026 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 """

"""Render Markdown as plain ASCII text, for reading on the board's console.

    yasos_venv/bin/python scripts/md2txt.py apps/ydb/docs/plan.md \\
        [-o plan.txt] [-w 78]

Headings are underlined, paragraphs and lists reflowed to the width, code
blocks kept verbatim, tables drawn as +---+ grids with wrapped cells.  It
is pandoc's plain writer (pypandoc_binary, scripts/requirements.txt) with
the scripts/md2txt.lua filter.  Without -o the text goes to stdout.
"""

import argparse
import pathlib
import sys

try:
    import pypandoc
except ImportError:
    sys.exit("md2txt: pypandoc missing -- run with yasos_venv/bin/python "
             "(yasos_venv/bin/pip install -r scripts/requirements.txt)")

HERE = pathlib.Path(__file__).resolve().parent


def render(path: pathlib.Path, width: int) -> str:
    text = pypandoc.convert_file(
        str(path), "plain-simple_tables-multiline_tables-pipe_tables",
        format="gfm",
        extra_args=[f"--columns={width}", "--wrap=auto",
                    f"--lua-filter={HERE / 'md2txt.lua'}"])
    # The board console is ASCII; say so instead of shipping mojibake.
    bad = sorted({c for c in text if ord(c) > 0x7f})
    if bad:
        print(f"md2txt: {path}: non-ASCII characters kept: {''.join(bad)}",
              file=sys.stderr)
    return text


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("input", type=pathlib.Path)
    ap.add_argument("-o", "--output", type=pathlib.Path)
    ap.add_argument("-w", "--width", type=int, default=78)
    args = ap.parse_args()
    text = render(args.input, args.width)
    if args.output:
        args.output.write_text(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
