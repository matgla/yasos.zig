#!/usr/bin/env python3
"""Capture cold/warm FAT and ext4 cache traffic with a profiling kernel.

The partitioned image uses QEMU's RAM-backed disk, not an SD timing model.
Counts are valid; elapsed times are not board predictions. Raw serial logs
and the exact kernel/rootfs hashes accompany the JSON for later comparisons.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

from yasos_device import QemuMount, REPO_ROOT, run, sdcard_image

sys.path.insert(0, str(REPO_ROOT / "tests"))
from smoke.kernel_profile import RUN_RE, parse_lines


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def measure(guest, name, command, expected_rc=0):
    guest.session.file.flush()
    offset = Path(guest.session.log_path).stat().st_size
    rc = run(guest.session, command, echo=False)
    guest.session.file.flush()
    with open(guest.session.log_path, encoding="utf-8", errors="replace") as log:
        log.seek(offset)
        lines = log.readlines()
        profile = parse_lines(lines).to_dict()
    if rc != expected_rc:
        raise RuntimeError(f"{name}: exit status {rc}: {command}")
    if not profile["caches"]:
        raise RuntimeError("no cacheprof records; use a perf-profiling kernel")
    counts = profile["caches"]
    lengths = sum(value for key, value in counts.items() if key.startswith("romfs_len"))
    if lengths != counts.get("romfs_hits", 0) + counts.get("romfs_misses", 0):
        raise RuntimeError(f"{name}: inconsistent romfs lookup accounting")
    if counts.get("ext4_cached_sectors", 0) > counts.get("ext4_read_sectors", 0):
        raise RuntimeError(f"{name}: cached ext4 traffic exceeds total traffic")
    print(f"{name}: {json.dumps(profile['caches'], sort_keys=True)}", flush=True)
    runs = [dict((key, int(value)) for key, value in match.groupdict().items())
            for line in lines if (match := RUN_RE.search(line))]
    return {"command": command, "rc": rc, "profile": profile, "runs": runs}


def capture(kernel, out, backend):
    work = out / backend
    work.mkdir(parents=True, exist_ok=True)
    payload = out / "payload"
    image = sdcard_image(out / "sdcard.img") if backend == "ext4" else None
    results = {}
    with QemuMount([(payload, "")], kernel=kernel, image=image,
                   work=work, keep_work=True) as guest:
        meminfo = []
        if run(guest.session, "cat /proc/meminfo", echo=False, on_line=meminfo.append):
            raise RuntimeError("cannot read /proc/meminfo")
        (work / "meminfo.txt").write_text("\n".join(meminfo) + "\n")
        dest = "/home/cacheprobe" if backend == "ext4" else "/mnt/cacheprobe"
        if backend == "ext4":
            setup = (f"mkdir -p {dest} && cp -r /usr/include {dest}/include && "
                     f"printf '#include <stdio.h>\\nint main(void){{puts(\"cacheprobe\");return 0;}}\\n' > {dest}/hello.c && "
                     f"cp /lib/libc.so {dest}/data.bin")
        else:
            setup = f"mkdir -p {dest} && cp /mnt/hello.c {dest}/hello.c && cp /mnt/data.bin {dest}/data.bin"
        if run(guest.session, setup, echo=False):
            raise RuntimeError(f"{backend}: setup failed")
        # The setup warms metadata. 'first' means the first measured read,
        # not an assertion that every cache line is cold after creating files.
        for label in ("first", "again"):
            results[f"read-{label}"] = measure(guest, f"{backend}/read-{label}",
                f"cat {dest}/data.bin > /dev/null")
        include = f"-I{dest}/include " if backend == "ext4" else ""
        for label in ("first", "again"):
            results[f"compile-{label}"] = measure(guest, f"{backend}/compile-{label}",
                f"tcc -bench -O2 {include}{dest}/hello.c -o {dest}/hello")
        for label in ("first", "again"):
            results[f"spawn-{label}"] = measure(guest, f"{backend}/spawn-{label}", f"{dest}/hello")
        # Regression check: bytes written through the filesystem remain visible
        # on a subsequent open/read (and can never be mistaken for a cache hit).
        results["write-read"] = measure(guest, f"{backend}/write-read",
            f"sh -c 'echo changed > {dest}/fresh; test \"$(cat {dest}/fresh)\" = changed'")
        results["rename-unlink"] = measure(guest, f"{backend}/rename-unlink",
            f"sh -c 'mv {dest}/fresh {dest}/renamed && test \"$(cat {dest}/renamed)\" = changed && "
            f"rm {dest}/renamed && test ! -e {dest}/renamed'")
        results["romfs-overflow"] = measure(guest, f"{backend}/romfs-overflow",
            "cat /usr/include/" + "x" * 64 + " > /dev/null", expected_rc=1)
        if not results["romfs-overflow"]["profile"]["caches"].get("romfs_overflow"):
            raise RuntimeError("long romfs lookup was not counted as overflow")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=REPO_ROOT / ".cache/vfs_cache_baseline")
    parser.add_argument("--backends", default="fat,ext4")
    parser.add_argument("--config", type=Path, default=REPO_ROOT / "config/target/config.json",
                        help="config.json used to build this kernel (recorded with results)")
    parser.add_argument("--board-model", action="store_true",
                        help="use the RP2350 timing plugin; supply a board-shaped kernel")
    args = parser.parse_args()
    backends = args.backends.split(",")
    if any(backend not in ("fat", "ext4") for backend in backends):
        parser.error("--backends must contain fat and/or ext4")
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    if args.board_model:
        from board_model import AN524_ARGS, PLUGIN, QEMU_DIR, plugin_args
        os.environ["YASOS_QEMU_BIN"] = str(QEMU_DIR / "qemu-system-arm")
        os.environ["YASOS_QEMU_EXTRA_ARGS"] = f"{AN524_ARGS} -d plugin -plugin {PLUGIN},{plugin_args(args.kernel)}"
    payload = args.out / "payload"
    payload.mkdir(exist_ok=True)
    (payload / "hello.c").write_text('#include <stdio.h>\nint main(void){puts("cacheprobe");return 0;}\n')
    (payload / "data.bin").write_bytes(bytes(range(256)) * 256)
    results = {
        "kernel_sha256": digest(args.kernel),
        "rootfs_sha256": digest(REPO_ROOT / "rootfs.img"),
        "config": json.loads(args.config.read_text()),
        "note": "RAM-backed block device; metadata warmed by setup; no SD timing claims",
        "backends": {},
    }
    if args.board_model:
        results["board_model_plugin_sha256"] = digest(PLUGIN)
        results["board_model_args"] = os.environ["YASOS_QEMU_EXTRA_ARGS"]
    for backend in backends:
        results["backends"][backend] = capture(args.kernel, args.out, backend)
        (args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
