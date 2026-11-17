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

"""Replace identical files in a rootfs staging tree with relative symlinks.

    scripts/rootfs_dedupe.py rootfs [--dry-run]
    scripts/rootfs_dedupe.py rootfs --undo

romfs (genromfs) has no hard links, so every copy of a file costs its full
size in the image.  build_rootfs.sh installs tinycc's runtime and headers
twice -- usr/lib/tcc/{include,fp,armv8m-libtcc1.a} next to usr/include and
usr/lib -- and the float libraries under two names each.  For each group of
byte-identical files one copy stays a file and the others become symlinks
to it, so every path still works.

The copy that stays: one outside usr/lib/tcc/ if there is one (usr/include
and usr/lib are where programs look first), then the shortest path, then
the first in sort order -- the same choice on every build.

Files under 64 bytes are left alone: a romfs symlink costs a 16-byte header
plus its name and target, so a tiny file gains nothing.  Empty files too.

rootfs/ is a staging tree that later builds install into again, and cp onto
a symlink writes through it -- into the copy that stayed.  So the links made
are listed in .cache/rootfs_dedupe.list, and --undo (build_rootfs.sh runs it
before anything is installed) turns each back into a copy of its target.
"""

import argparse
import hashlib
import os
import shutil
import sys
from pathlib import Path

MIN_SIZE = 64
MANIFEST = Path(__file__).resolve().parents[1] / ".cache/rootfs_dedupe.list"


def undo(root):
    if not MANIFEST.exists():
        return 0
    restored = 0
    for rel in MANIFEST.read_text().split("\n"):
        link = root / rel
        if rel and link.is_symlink() and link.resolve().is_file():
            target = link.resolve()
            link.unlink()
            shutil.copy2(target, link)
            restored += 1
    MANIFEST.unlink()
    print(f"rootfs_dedupe: {restored} link(s) turned back into files")
    return 0


def keep_order(path, root):
    rel = path.relative_to(root).as_posix()
    return (rel.startswith("usr/lib/tcc/"), len(rel), rel)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("root", type=Path)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--undo", action="store_true", help="restore the files a previous run linked")
    args = ap.parse_args()
    root = args.root.resolve()
    if args.undo:
        return undo(root)

    groups = {}
    for dirpath, _, names in os.walk(root):
        for name in names:
            path = Path(dirpath) / name
            if path.is_symlink() or not path.is_file():
                continue
            size = path.stat().st_size
            if size < MIN_SIZE:
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            groups.setdefault((size, digest), []).append(path)

    saved = 0
    linked = 0
    made = []
    for (size, _), paths in sorted(groups.items()):
        if len(paths) < 2:
            continue
        paths.sort(key=lambda p: keep_order(p, root))
        keep = paths[0]
        for dup in paths[1:]:
            target = os.path.relpath(keep, dup.parent)
            print(f"rootfs_dedupe: {dup.relative_to(root)} -> {target} ({size} bytes)")
            if not args.dry_run:
                dup.unlink()
                dup.symlink_to(target)
                made.append(dup.relative_to(root).as_posix())
            saved += size
            linked += 1
    if made:
        MANIFEST.parent.mkdir(parents=True, exist_ok=True)
        old = MANIFEST.read_text().split("\n") if MANIFEST.exists() else []
        MANIFEST.write_text("\n".join(sorted(set(filter(None, old + made)))) + "\n")
    print(f"rootfs_dedupe: {linked} duplicate(s) linked, {saved} bytes saved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
