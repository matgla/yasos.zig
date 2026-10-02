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

"""Put a host directory in front of a YasOS shell and run commands there.

Two ways to get files onto a target, one way to drive it once they are there:

  QemuMount   boots the mps3-an524 kernel with the directory as a FAT volume at
              /mnt. Nothing is transferred: the volume is laid into the file that
              backs guest RAM, and whatever the guest writes to /mnt can be read
              back out of that file after qemu exits (pull).
  uart_send   pushes the directory over the debug-probe UART with the zmodem
              batch sender scripts/transfer.py uses, to an absolute directory on
              the board.

Both hand back a smoke-framework Session, and `run` executes a shell command on
it and returns its exit status, streaming the output as it comes.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

# The smoke framework needs pyserial; it is imported where a target is driven,
# so the image and sync helpers also run under a plain python3.

FATIMG = REPO_ROOT / "scripts" / "fatimg" / "fatimg"
DEFAULT_KERNEL = REPO_ROOT / "zig-out" / "bin" / "yasos_kernel"
AN524_EXTRA_ARGS = ("-global sse-200.CPU0_FPU=on -global sse-200.CPU1_FPU=on "
                    "-global sse-200.CPU0_DSP=on -global sse-200.CPU1_DSP=on")
MOUNT_POINT = "/mnt"


class DeviceError(Exception):
    """A problem the user can fix, reported without a traceback."""


# ---- the FAT volume ----

def fat_window():
    """(offset into guest RAM, size) of the an524's fatdisk, from its linker script."""
    import build_smoke_fatdisk
    return build_smoke_fatdisk.FATDISK_OFFSET, build_smoke_fatdisk.FATDISK_SIZE


def _ensure_fatimg():
    if not FATIMG.is_file() or FATIMG.stat().st_mtime < (FATIMG.parent / "fatimg.c").stat().st_mtime:
        subprocess.run([str(FATIMG.parent / "build.sh")], check=True, stdout=subprocess.DEVNULL)


# Never copied onto a target: git stays on the PC, and build caches are big.
WORKSPACE_EXCLUDES = (".git", ".zig-cache", "zig-out", "__pycache__", "*.pyc", ".DS_Store",
                      "*.target")  # a conflict's other side, see merge_into_host


def _excluded(name, excludes):
    import fnmatch
    return any(fnmatch.fnmatch(name, pattern) for pattern in excludes)


FDISK_DIR = REPO_ROOT / "apps/fdisk"
MKFS_DIR = REPO_ROOT / "apps/mkfs"
CARDREFORMAT = REPO_ROOT / "usr/bin/cardreformat"
# The card layout shrunk to QEMU's 16 MiB fatdisk window: fdisk "Last sector"
# answers for /boot, /var and /opt; /home takes the rest.
QEMU_SDCARD_SIZES = {"BOOT_SIZE": "+2M", "VAR_SIZE": "+4M", "OPT_SIZE": "+2M"}


def sdcard_image(image: Path, sizes=QEMU_SDCARD_SIZES) -> Path:
    """A partitioned SD card image the size of the fatdisk window, laid out by
    usr/bin/cardreformat with the host builds of fdisk and mkfs -- the kernel
    finds its partitions as /dev/fatdisk0p1..4 and /etc/fstab mounts them by
    label."""
    subprocess.run(["make", "-s", "-C", str(FDISK_DIR), "host"], check=True)
    subprocess.run(["make", "-s", "-C", str(MKFS_DIR), "host"], check=True)
    _, window = fat_window()
    image.parent.mkdir(parents=True, exist_ok=True)
    if image.exists():
        image.unlink()
    with open(image, "wb") as f:
        f.truncate(window)
    env = dict(os.environ, **sizes,
               FDISK=str(FDISK_DIR / "build/host/fdisk"),
               MKFS_FAT=str(MKFS_DIR / "build/host/mkfs.fat"),
               MKFS_EXT4=str(MKFS_DIR / "build/host/mkfs.ext4"))
    subprocess.run([str(CARDREFORMAT), "-y", str(image)], check=True, env=env,
                   stdout=subprocess.DEVNULL)
    return image


def build_fat_image(image: Path, sources, excludes=()) -> int:
    """Format *image* as the whole fatdisk window and copy *sources* into it.

    *sources* is a list of (host directory, path inside the volume); an empty
    list makes an empty volume. Returns the number of payload bytes."""
    _ensure_fatimg()
    _, window = fat_window()
    listing, total, count = [], 0, 0
    for host_dir, prefix in sources:
        host_dir = Path(host_dir)
        if not host_dir.is_dir():
            raise DeviceError(f"{host_dir}: not a directory")
        for dirpath, dirnames, filenames in os.walk(host_dir):
            dirnames[:] = sorted(d for d in dirnames if not _excluded(d, excludes))
            for name in sorted(filenames):
                local = Path(dirpath) / name
                if not local.is_file() or _excluded(name, excludes):
                    continue
                inside = local.relative_to(host_dir).as_posix()
                if prefix:
                    inside = f"{prefix.strip('/')}/{inside}"
                if "\t" in str(local) or "\n" in str(local):
                    raise DeviceError(f"{local}: tab or newline in the name")
                listing.append(f"{local}\t{inside}\n")
                total += local.stat().st_size
                count += 1
    # Clusters round every file up; 4 KiB each is the worst case at this size.
    needed = total + count * 4096
    if needed > window * 0.97:
        raise DeviceError(
            f"{count} files, {total / 1048576:.1f} MiB (~{needed / 1048576:.1f} MiB on FAT) do not "
            f"fit the {window // 1048576} MiB fatdisk window; use the UART transfer or a subset")
    image.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(FATIMG), "mkfs", str(image), str(window // 1024)],
                   check=True, stdout=subprocess.DEVNULL)
    if listing:
        list_file = image.with_suffix(".list")
        list_file.write_text("".join(listing))
        subprocess.run([str(FATIMG), "cpmany", str(image), str(list_file)],
                       check=True, stdout=subprocess.DEVNULL)
    return total


# ---- running commands ----

_RC_MARK = "@@yasos-rc="
_RC_RE = re.compile(re.escape(_RC_MARK) + r"(-?\d+)")


def _session_class():
    from tests.smoke.framework.session import Session
    return Session


def run(session, command: str, silence: float = 600.0, echo=True, on_line=None) -> int:
    """Run *command* in the target shell and return its exit status.

    *silence* bounds the time between two output lines, not the whole run, so a
    long build is fine as long as it keeps printing."""
    rc = None

    def line(text):
        nonlocal rc
        match = _RC_RE.search(text)
        if match:
            rc = int(match.group(1))
            return False
        if echo:
            print(text, flush=True)
        if on_line is not None:
            on_line(text)
        return False

    session.write_command(f"{command}; echo {_RC_MARK}$?")
    session.wait_for_prompt_streaming(on_line=line, timeout=silence)
    if rc is None:
        raise DeviceError(f"no exit status seen for: {command}")
    return rc


# ---- QEMU ----

class QemuMount:
    """A fresh an524 guest with *sources* on a FAT volume at /mnt.

        with QemuMount([(Path("out"), "")]) as guest:
            run(guest.session, "ls /mnt")
        guest.pull(Path("back"))
    """

    def __init__(self, sources, kernel=None, work=None, keep_work=False, image=None):
        self.kernel = Path(kernel or os.environ.get("YASOS_QEMU_KERNEL") or DEFAULT_KERNEL).resolve()
        if not self.kernel.is_file():
            raise DeviceError(f"kernel {self.kernel} not found (build it with zig build, qemu_mps3_an524 config)")
        self.sources = sources
        self._own_work = work is None
        self.work = Path(work or tempfile.mkdtemp(prefix="qemu_mount_", dir=REPO_ROOT / ".cache"))
        self.keep_work = keep_work
        self.session = None
        self.image = self.work / "fatdisk.img"
        self.backing = self.work / "mem_main.bin"
        # A ready-made image for the window instead of a FAT volume built from
        # *sources* -- a partitioned SD card image, say (see sdcard_image).
        self.prebuilt = Path(image) if image else None

    def __enter__(self):
        self.work.mkdir(parents=True, exist_ok=True)
        if self.prebuilt is not None:
            shutil.copyfile(self.prebuilt, self.image)
            payload = self.image.stat().st_size
        else:
            payload = build_fat_image(self.image, self.sources)
        offset, _ = fat_window()
        # Peer sessions kill stray guests by the name "qemu-system-arm"; a guest
        # reached through a differently named link survives that.
        shim = self.work / "qemu-yasos-mount"
        if not shim.exists():
            qemu = shutil.which(os.environ.get("YASOS_QEMU_BIN", "qemu-system-arm"))
            if qemu is None:
                raise DeviceError("qemu-system-arm not found")
            shim.symlink_to(qemu)
        os.environ.update({
            "YASOS_QEMU_KERNEL": str(self.kernel),
            "YASOS_QEMU_BIN": str(shim),
            "YASOS_QEMU_MACHINE": "mps3-an524",
            "YASOS_QEMU_EXTRA_ARGS": os.environ.get("YASOS_QEMU_EXTRA_ARGS", AN524_EXTRA_ARGS),
            "YASOS_QEMU_RAM_BACKING_DIR": str(self.work),
            "YASOS_QEMU_FATDISK_IMAGE": str(self.image),
            "YASOS_QEMU_FATDISK_OFFSET": hex(offset),
            "YASOS_QEMU_PRESERVE_STATE": "1",
            "YASOS_QEMU_LOG_DIR": str(self.work),
            "YASOS_SMOKE_LOG_DIR": str(self.work),
            "PYTEST_XDIST_WORKER": "main",
        })
        print(f"qemu: {payload / 1048576:.1f} MiB on {MOUNT_POINT}, kernel {self.kernel}, "
              f"logs in {self.work}", file=sys.stderr)
        Session = _session_class()
        Session.backend = None
        self.session = Session("qemu_mount")
        return self

    def __exit__(self, *exc):
        self.stop()
        if self._own_work and not self.keep_work:
            shutil.rmtree(self.work, ignore_errors=True)
        return False

    def stop(self):
        """Stop the guest; /mnt stays readable through pull()."""
        if self.session is not None:
            self.session.close()
            self.session = None
            _session_class().finalize()

    def snapshot(self, image: Path) -> Path:
        """The fatdisk window as the guest left it, as a raw image."""
        offset, window = fat_window()
        image.parent.mkdir(parents=True, exist_ok=True)
        with open(self.backing, "rb") as src, open(image, "wb") as dst:
            src.seek(offset)
            dst.write(src.read(window))
        return image

    def pull(self, host_dir: Path):
        """Copy the guest's /mnt, as it was when the guest stopped, to *host_dir*."""
        snapshot = self.snapshot(self.work / "fatdisk.out.img")
        host_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(FATIMG), "pull", str(snapshot), str(host_dir)], check=True)


# ---- a workspace kept in step with a host directory ----
#
# The target has no git and no network. The PC keeps the checkout; the target
# works on a copy, and sync brings back what the target changed. It is a
# three-way merge against what both sides had at the last sync, so a file edited
# on the PC while the target ran is never overwritten: if both sides changed it,
# the target's version is kept next to it as <file>.target and reported.

def snapshot(root: Path, excludes=WORKSPACE_EXCLUDES) -> dict:
    """{relative path: sha256} of every file under *root*."""
    import hashlib
    found = {}
    if not root.is_dir():
        return found
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not _excluded(d, excludes)]
        for name in filenames:
            path = Path(dirpath) / name
            if _excluded(name, excludes) or not path.is_file():
                continue
            found[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return found


def merge_into_host(base: dict, target: dict, host_dir: Path, fetch) -> dict:
    """Apply what the target changed since *base* to *host_dir*.

    *target* is the target's manifest; *fetch(paths)* returns a directory
    holding the target's copies of those paths. Returns
    {"updated": [...], "added": [...], "deleted": [...], "conflicts": [...]}."""
    host = snapshot(host_dir)
    report = {"updated": [], "added": [], "deleted": [], "conflicts": []}
    wanted = [p for p in sorted(set(base) | set(target))
              if target.get(p) not in (base.get(p), host.get(p)) and target.get(p) is not None]
    copies = fetch(wanted) if wanted else None
    for path in sorted(set(base) | set(target) | set(host)):
        b, t, h = base.get(path), target.get(path), host.get(path)
        if t == b or t == h:
            continue                       # the target did not change it, or both agree
        if h != b:                         # both sides changed it, differently
            if t is not None:
                dst = host_dir / (path + ".target")
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(copies / path, dst)
            report["conflicts"].append(path)
            continue
        if t is None:
            (host_dir / path).unlink()
            report["deleted"].append(path)
            continue
        dst = host_dir / path
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(copies / path, dst)
        report["added" if b is None else "updated"].append(path)
    return report


def merge_back(target_copy: Path, host_dir: Path, base: dict, excludes=WORKSPACE_EXCLUDES) -> dict:
    """merge_into_host with the whole target at hand in *target_copy*."""
    return merge_into_host(base, snapshot(target_copy, excludes), host_dir, lambda paths: target_copy)


def print_merge_report(report, host_dir, stream=sys.stderr):
    changed = sum(len(v) for k, v in report.items() if k != "conflicts")
    if not changed and not report["conflicts"]:
        print(f"sync: nothing changed on the target", file=stream)
        return
    for kind, sign in (("added", "A"), ("updated", "M"), ("deleted", "D")):
        for path in report[kind]:
            print(f"  {sign} {path}", file=stream)
    for path in report["conflicts"]:
        print(f"  C {path}  (changed on both sides; the target's copy is {path}.target)", file=stream)
    print(f"sync: {changed} file(s) brought back into {host_dir}"
          + (f", {len(report['conflicts'])} conflict(s)" if report["conflicts"] else ""), file=stream)


def seed_backing(host_dir: Path, backing: Path, ram_size: int, state: Path):
    """Create guest RAM backing with *host_dir* on the fatdisk; remember what was sent."""
    import json
    offset, _ = fat_window()
    image = backing.with_suffix(".fat.img")
    build_fat_image(image, [(host_dir, "")], WORKSPACE_EXCLUDES)
    with open(backing, "wb") as f:
        f.truncate(ram_size)
        f.seek(offset)
        f.write(image.read_bytes())
    image.unlink()
    state.write_text(json.dumps(snapshot(host_dir)))


def sync_backing(backing: Path, host_dir: Path, state: Path) -> dict:
    """Read the guest's /mnt out of *backing* and merge it into *host_dir*."""
    import json
    offset, window = fat_window()
    work = Path(tempfile.mkdtemp(prefix="sync_", dir=backing.parent))
    try:
        image = work / "fat.img"
        with open(backing, "rb") as src:
            src.seek(offset)
            image.write_bytes(src.read(window))
        copy = work / "mnt"
        subprocess.run([str(FATIMG), "pull", str(image), str(copy)], check=True)
        report = merge_back(copy, host_dir, json.loads(state.read_text()))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    state.write_text(json.dumps(snapshot(host_dir)))
    return report


# ---- keeping a directory on the board in step, over the UART ----
#
# The same three-way rules as the QEMU /mnt, with the state file holding what
# the board had after the last push or pull: a file the PC changed since then
# goes to the board (push), a file the board changed comes back (pull), and a
# file both changed is reported and left alone on the board (push) or kept
# beside the PC's as <file>.target (pull).

def _sh_quote(text: str) -> str:
    return "'" + text.replace("'", "'\\''") + "'"


def target_manifest(session, target_dir: str, excludes=WORKSPACE_EXCLUDES) -> dict:
    """{relative path: sha256} of the files under *target_dir* on the board."""
    found = {}

    def line(text):
        digest, sep, name = text.partition("  ")
        if not sep or len(digest) != 64:
            return
        name = name[2:] if name.startswith("./") else name
        if any(_excluded(part, excludes) for part in name.split("/")):
            return
        found[name] = digest

    # The board's sha256sum prints the bare digest of its first argument only,
    # and `find -exec sha256sum {} +` hangs there, so one file per call.
    rc = run(session, f"test -d {_sh_quote(target_dir)} && cd {_sh_quote(target_dir)} && "
                      'find . -type f | while read -r f; do echo "$(sha256sum "$f")  $f"; done; '
                      "r=$?; cd /; test $r = 0",
             echo=False, on_line=line)
    return found if rc == 0 else {}


def sync_state_path(host_dir: Path, target_dir: str, kind: str = "uart") -> Path:
    import hashlib
    key = hashlib.sha1(f"{kind}|{host_dir.resolve()}|{target_dir}".encode()).hexdigest()[:16]
    path = REPO_ROOT / ".cache" / "target_sync" / f"{key}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def _load_state(state: Path) -> dict:
    import json
    return json.loads(state.read_text()) if state.is_file() else {}


def _save_state(state: Path, manifest: dict):
    import json
    state.write_text(json.dumps(manifest, sort_keys=True))


def uart_pull(session, host_dir: Path, target_dir: str, sz: str = None) -> dict:
    """Bring what the board changed in *target_dir* back into *host_dir*.

    *sz* is the board's sender (default: $YASOS_SZ, else sz from its PATH)."""
    sz = sz or os.environ.get("YASOS_SZ", "sz")
    from tests.smoke.framework import file_transfer
    state = sync_state_path(host_dir, target_dir)
    base = _load_state(state)
    target = target_manifest(session, target_dir)
    root = target_dir.rstrip("/") + "/"

    def fetch(paths):
        work = Path(tempfile.mkdtemp(prefix="pull_", dir=REPO_ROOT / ".cache"))
        listing = work / "list"
        listing.write_text("".join(root + p + "\n" for p in paths))
        file_transfer.send_files(session, [(listing, "/tmp/.yasos_sz.list")])
        wanted = set(paths)
        got = file_transfer.receive_files(
            session, f"{sz} --strip {_sh_quote(root)} --list /tmp/.yasos_sz.list",
            lambda name: work / "files" / name if name in wanted else None)
        missing = wanted - {name for name, _, _ in got}
        if missing:
            raise DeviceError(f"the board did not send {sorted(missing)[:5]}")
        return work / "files"

    host_dir.mkdir(parents=True, exist_ok=True)
    report = merge_into_host(base, target, host_dir, fetch)
    _save_state(state, target)
    return report


def uart_push(session, host_dir: Path, target_dir: str) -> dict:
    """Send what the PC changed in *host_dir* since the last sync to the board."""
    from tests.smoke.framework import file_transfer
    state = sync_state_path(host_dir, target_dir)
    base = _load_state(state)
    target = target_manifest(session, target_dir)
    host = snapshot(host_dir)
    report = {"updated": [], "added": [], "deleted": [], "conflicts": []}
    send, remove = [], []
    for path in sorted(set(base) | set(target) | set(host)):
        b, t, h = base.get(path), target.get(path), host.get(path)
        if h == b or h == t:
            continue                       # the PC did not change it, or both agree
        if t != b or (host_dir / (path + ".target")).exists():
            # Changed on both sides; a pull left the board's copy beside it
            # until someone deletes <file>.target to say it is resolved.
            report["conflicts"].append(path)
            continue
        if h is None:
            remove.append(path)
            report["deleted"].append(path)
        else:
            send.append(path)
            report["added" if t is None else "updated"].append(path)
    root = target_dir.rstrip("/")
    if send:
        file_transfer.send_files(session, [(host_dir / p, f"{root}/{p}") for p in send])
    for i in range(0, len(remove), 20):
        run(session, "rm -f " + " ".join(_sh_quote(f"{root}/{p}") for p in remove[i:i + 20]), echo=False)
    new_state = dict(target)
    for path in send:
        new_state[path] = host[path]
    for path in remove:
        new_state.pop(path, None)
    _save_state(state, new_state)
    return report


# ---- UART ----

def uart_session(serial_device=None):
    """A Session on the debug-probe UART, without resetting a board that answers."""
    if serial_device:
        os.environ["SERIAL_DEVICE"] = serial_device
    os.environ.pop("YASOS_QEMU_KERNEL", None)
    Session = _session_class()
    Session.target_needs_reset = False
    return Session("uart")


def uart_send(session, host_dir: Path, dest: str, timeout: float = 30.0) -> int:
    """Send everything under *host_dir* into the board's absolute *dest*."""
    if not dest.startswith("/"):
        raise DeviceError(f"destination {dest!r} must be absolute")
    transfers = []
    for dirpath, dirnames, filenames in os.walk(host_dir):
        dirnames.sort()
        for name in sorted(filenames):
            local = Path(dirpath) / name
            transfers.append((local, f"{dest.rstrip('/')}/{local.relative_to(host_dir).as_posix()}"))
    total = sum(os.path.getsize(local) for local, _ in transfers)
    print(f"uart: sending {len(transfers)} files, {total / 1048576:.1f} MiB to {dest}", file=sys.stderr)
    from tests.smoke.framework import file_transfer
    started = time.monotonic()
    sent = file_transfer.send_files(session, transfers, timeout=timeout)
    print(f"uart: sent in {time.monotonic() - started:.0f} s", file=sys.stderr)
    return sent
