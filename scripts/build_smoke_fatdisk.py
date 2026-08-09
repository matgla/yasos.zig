#!/usr/bin/env python3
"""Build the smoke source corpus into a FAT image and map it into QEMU's RAM.

The guest's fatdisk window is a fixed slice of the file that backs QEMU's RAM
under a ``memory-backend-file,share=on`` launch. So the corpus can be put on the
device by writing it into that slice on the host -- no transfer at all -- and it
survives every relaunch, because the file outlives the qemu process.

That is worth doing because the alternative is not cheap: the corpus is 4.13 MiB
of mostly sub-kilobyte files, the RAM-backed disk is reformatted on every boot,
and the harness relaunches qemu between tests. Pushing it over ZMODEM again each
time is the single largest cost in a smoke run.

Usage:
  scripts/build_smoke_fatdisk.py --backing /path/mem0.bin [--image /path/fat.img]
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FATIMG = REPO / "scripts" / "fatimg" / "fatimg"

# MUST match hal/boards/qemu_mps3_an524/qemu_mps3_an524.zig + its linker_script.ld.
RAM_BASE = 0x60000000
RAM_SIZE = 2 * 1024 * 1024 * 1024  # qemu rejects any other size for mps3-an524
FATDISK_ADDR = 0x70000000
FATDISK_SIZE = 16 * 1024 * 1024
FATDISK_OFFSET = FATDISK_ADDR - RAM_BASE

# Where the corpus lands inside the FAT volume. The guest mounts this disk at
# /mnt (source/main.zig), so "ci/sources/v2" here is "/mnt/ci/sources/v2" there
# -- which is what REMOTE_SOURCES_ROOT in tests/smoke/tcc_suite_test.py names.
CORPUS_PREFIX = "ci/sources/v2"


def _corpus():
    """Remote-relative path -> host path, straight from the smoke harness.

    Importing the harness rather than re-deriving the file list keeps the image
    honest: whatever the tests will ask the device for is what gets written.
    """
    sys.path.insert(0, str(REPO / "tests"))
    os.environ.setdefault("YASOS_SMOKE_IMPORT_ONLY", "1")
    from smoke import tcc_suite_test as suite

    mapping = {}
    for remote, local in suite._iter_corpus_sources():
        # Remote paths are absolute under the sources root; re-anchor them.
        rel = remote[len(suite.REMOTE_SOURCES_ROOT):].lstrip("/")
        mapping[f"{CORPUS_PREFIX}/{rel}"] = str(local)
    return mapping


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backing", required=True,
                    help="qemu RAM backing file (created sparse if absent)")
    ap.add_argument("--image", default=None,
                    help="intermediate FAT image path (default: alongside backing)")
    args = ap.parse_args()

    if not FATIMG.is_file():
        sys.exit("fatimg not built -- run scripts/fatimg/build.sh")

    backing = Path(args.backing)
    image = Path(args.image) if args.image else backing.with_suffix(".fat.img")

    corpus = _corpus()
    if not corpus:
        sys.exit("corpus is empty -- nothing to map")

    # One mount for the whole corpus: a fatimg run per file would spend all its
    # time mounting and unmounting a 16 MB image.
    listing = image.with_suffix(".list")
    listing.write_text(
        "".join(f"{host}\t0:/{fat}\n" for fat, host in sorted(corpus.items())),
        encoding="utf-8",
    )

    subprocess.run([str(FATIMG), "mkfs", str(image), str(FATDISK_SIZE // 1024)],
                   check=True)
    subprocess.run([str(FATIMG), "cpmany", str(image), str(listing)], check=True)

    # Sparse: qemu insists the backing file is exactly the machine's 2 GiB, but
    # only the pages the guest touches are ever allocated.
    backing.parent.mkdir(parents=True, exist_ok=True)
    with open(backing, "a+b") as f:
        f.truncate(RAM_SIZE)
    data = image.read_bytes()
    if len(data) > FATDISK_SIZE:
        sys.exit(f"FAT image {len(data)} B exceeds the {FATDISK_SIZE} B window")
    with open(backing, "r+b") as f:
        f.seek(FATDISK_OFFSET)
        f.write(data)

    print(f"mapped {len(corpus)} sources ({len(data) // 1024} KiB image) into "
          f"{backing} at offset 0x{FATDISK_OFFSET:X}")


if __name__ == "__main__":
    main()
