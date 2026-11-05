#!/usr/bin/env python3
"""A tinycc self-compile on the rig's board, timed; scripts/board_model.py is the fast
stand-in, this is the number that counts.

  board_selfhost.py --build                 # board config + rootfs + kernel, then -O0 and -O2
  board_selfhost.py --opt=-O0               # what this checkout has built, -O0 only
  board_selfhost.py --no-wait ; ... --logs  # leave it running, collect later

Everything on the rig stays in ~/selfhost_measure/<label> and images reach the shared
workdir only under the board lock, so sessions queue on the lock instead of flashing each
other's firmware.  <label> and the board's directory default to this checkout's name: a
tree on the card is another session's to change, and a manifest would then send too little.

Reads the rig from .cache/remote_smoke_runner.json (remote_smoke_tui.py --reconfigure).
"""
import argparse
import hashlib
import json
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
RUNNER_CONFIG = ".cache/remote_smoke_runner.json"
BOARD_DEFCONFIG = "configs/{board}_defconfig"
SUMMARY = re.compile(r"upload took|sent \d|manifest|SELFHOST link|stage 2 |RESULT|MEASURE (selfhost|ERROR)|memory full|fault|panic", re.I)


def log(msg):
    print(f">> {msg}", flush=True)


def rig_config():
    roots = [REPO, Path.home() / "repos/yasos.zig"]  # worktrees have no configuration of their own
    for root in roots:
        path = root / RUNNER_CONFIG
        if path.exists():
            return json.loads(path.read_text())
    sys.exit(f"no {RUNNER_CONFIG}: run scripts/remote_smoke_tui.py --reconfigure")


class Rig:
    def __init__(self, target, port):
        self.target, self.port = target, str(port)

    def ssh(self, cmd, check=True, capture=True):
        r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-p", self.port, self.target, cmd],
                           stdin=subprocess.DEVNULL, capture_output=capture, text=True)
        if check and r.returncode:
            sys.exit(f"ssh {cmd[:80]}: {r.stderr}")
        return r

    def send(self, sources, dest):
        files = [str(f) for f in sources if f.is_file()]
        subprocess.run(["scp", "-q", "-P", self.port, *files, f"{self.target}:{dest}"], check=True)

    def fetch(self, source, dest):
        return subprocess.run(["scp", "-q", "-r", "-P", self.port, f"{self.target}:{source}", str(dest)]).returncode


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(board):
    subprocess.run(["zig", "build", "defconfig", f"-Ddefconfig_file={BOARD_DEFCONFIG.format(board=board)}"], cwd=REPO, check=True)
    subprocess.run(["./build_rootfs.sh", "-c", "-o", "rootfs.img"], cwd=REPO, check=True)


def check_built(board):
    built = json.loads((REPO / "config/target/config.json").read_text()).get("board") if (REPO / "config/target/config.json").exists() else None
    if not built or not board.startswith(built):  # the defconfig may name more than the board
        sys.exit(f"this checkout is configured for {built}, the rig has {board}: use --build")
    for f in ("rootfs.img", "zig-out/bin/yasos_kernel"):
        if not (REPO / f).exists():
            sys.exit(f"{f} missing: use --build")


def collect(rig, d, local, levels):
    """Fetch the logs and print what they say; True when every step succeeded."""
    local.mkdir(parents=True, exist_ok=True)
    driver = rig.ssh(f"cat {d}/driver.out", check=False).stdout
    rig.fetch(f"{d}/logs/.", local)
    (local / "driver.out").write_text(driver)
    print(driver, end="")
    for level in levels:
        path = local / f"{level}.log"
        if path.exists():
            print(f"--- {level}: {path}")
            for line in path.read_text(errors="replace").splitlines():
                if SUMMARY.search(line):
                    print(line[:110])
    return "BOARD_DONE" in driver and not re.search(r"measure rc=[1-9]", driver)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--opt", action="append", help="level to compile tinycc at, repeatable (default: -O0 and -O2)")
    ap.add_argument("--build", action="store_true", help="configure for the rig's board and build rootfs + kernel first")
    ap.add_argument("--label", default=REPO.name, help="directory on the rig (default: %(default)s)")
    ap.add_argument("--dest", help="absolute directory on the board (default: /root/selfhost-<label>)")
    ap.add_argument("--full-send", action="store_true", help="send everything, not the manifest's difference")
    ap.add_argument("--no-wait", action="store_true", help="start it and print how to watch")
    ap.add_argument("--logs", action="store_true", help="only collect the logs of the last run")
    args = ap.parse_args()
    levels = args.opt or ["-O0", "-O2"]
    cfg = rig_config()
    rig = Rig(cfg["ssh_target"], cfg.get("ssh_port", 22))
    remote = cfg.get("remote_repo_path", "~/yasos_remote_smoke")
    if not re.fullmatch(r"[\w.-]+", args.label):
        sys.exit(f"bad label {args.label!r}")
    dest = args.dest or f"/root/selfhost-{args.label}"
    d = f"selfhost_measure/{args.label}"
    local = REPO / ".cache/board_selfhost" / args.label
    if args.logs:
        return 0 if collect(rig, d, local, levels) else 1

    if args.build:
        build(cfg["board"])
    check_built(cfg["board"])
    rootfs, kernel = REPO / "rootfs.img", REPO / "zig-out/bin/yasos_kernel"
    rs, ks = sha256(rootfs), sha256(kernel)
    log(f"rootfs {rs[:16]} kernel {ks[:16]}")
    for level in levels:
        subprocess.run([sys.executable, "scripts/tcc_selfhost.py", "--prepare-only", "--stages", "2", f"--opt={level}",
                        "--work", str(local / f"work{level}")], cwd=REPO, check=True, stdout=subprocess.DEVNULL)

    if rig.ssh(f"pgrep -f {shlex.quote(d + '/rig/[r]un_selfhost.sh')}", check=False).stdout.strip():
        sys.exit(f"{args.label} is already running on the rig: --logs, or a different --label")
    rig.ssh(f"mkdir -p {d}/img {d}/py {d}/rig; rm -rf {d}/logs {d}/driver.out; " +
            "; ".join(f"rm -rf {d}/payload{level}; mkdir -p {d}/payload{level}" for level in levels))
    rig.send([rootfs, kernel], f"{d}/img/")
    rig.send([REPO / "scripts/yasos_device.py"], f"{d}/py/")
    rig.send(sorted((REPO / "scripts/rig").iterdir()), f"{d}/rig/")
    for level in levels:
        rig.send(sorted((local / f"work{level}/payload").iterdir()), f"{d}/payload{level}/")
    mode = "full" if args.full_send else "delta"
    # relative paths would break once the script changes directory
    cmd = (f"cd; D=$PWD/{d}; YASOS_RIG_REMOTE={remote} nohup bash $D/rig/run_selfhost.sh $D {rs} {ks} {dest} {mode} {' '.join(levels)} "
           f"> $D/driver.out 2>&1 < /dev/null &")
    rig.ssh(cmd, capture=False)
    log(f"queued on the board lock; board directory {dest}")
    log(f"watch: ssh {rig.target} 'tail -F {d}/driver.out {d}/logs/{levels[0]}.log'")
    if args.no_wait:
        return 0
    finished = re.compile(r"BOARD_DONE|NOLOCK|IMAGE CHANGED|reflash rc=[1-9]")
    while not finished.search(rig.ssh(f"cat {d}/driver.out 2>/dev/null", check=False).stdout):
        time.sleep(30)
    return 0 if collect(rig, d, local, levels) else 1


if __name__ == "__main__":
    sys.exit(main())
