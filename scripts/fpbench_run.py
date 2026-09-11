#!/usr/bin/env python3
"""Run apps/fpbench on the board and print the comparison table.

The four arms of apps/fpbench are four separate programs -- they have to be,
because they link four different __aeabi_ runtimes and those export the same
names, so one process can hold exactly one of them.  Running them therefore
means typing four commands at the board's shell and a fifth to join the
results, which is what this does over the rig's serial port.

Why not the smoke harness: this is a measurement, not a test.  It wants the
board otherwise idle (a preempted trial reads high by a whole 5 ms quantum, and
fpbench's minimum-over-trials only cancels that if some trial got a clean run),
it wants the raw transcript, and it wants to be cheap enough to repeat.

Why not `remote_smoke_tui.py --gdb-debug --cmd`: that attaches GDB afterwards
and hands the session to a human.

The serial parameters come from tests/smoke/framework/session.py -- 3 Mbaud,
`$ ` prompt.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shlex
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE_PATH = REPO_ROOT / ".cache" / "remote_smoke_runner.json"

# Executed on the board host by the rig's smoke venv (pyserial lives there).
REMOTE_DRIVER = r'''
import sys, time
import serial

PORT = sys.argv[1]
BAUD = int(sys.argv[2])
COMMANDS = sys.argv[3:]
PROMPT = b"$ "

ser = serial.Serial(PORT, BAUD, timeout=0.2)


def drain(seconds=0.4):
    end = time.time() + seconds
    out = b""
    while time.time() < end:
        chunk = ser.read(4096)
        if chunk:
            out += chunk
            end = time.time() + seconds
    return out


def read_until_prompt(timeout):
    # The shell redraws its prompt with an erase-to-EOL, so the tail is not
    # always the bare two characters; strip the escape before testing.
    end = time.time() + timeout
    out = b""
    while time.time() < end:
        chunk = ser.read(4096)
        if chunk:
            out += chunk
            tail = out.rstrip(b"\x1b[K")
            if tail.endswith(PROMPT):
                return out, True
    return out, False


# Wake the shell and throw away whatever was already on the wire.
ser.write(b"\r")
ser.flush()
drain(0.6)

for command in COMMANDS:
    ser.write(command.encode() + b"\r")
    ser.flush()
    # fpbench runs 15 arms x 7 trials; the software double divide arm alone can
    # take several seconds, so the budget is generous and the failure mode is a
    # printed timeout rather than a hang.
    body, ok = read_until_prompt(300)
    sys.stdout.write("=== %s ===\n" % command)
    sys.stdout.write(body.decode("utf-8", "replace"))
    sys.stdout.write("\n")
    sys.stdout.flush()
    if not ok:
        sys.stdout.write("!!! timed out waiting for the prompt after %r\n" % command)
        sys.exit(1)
'''


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--iters", default=None, help="iterations per trial to pass to each arm")
    parser.add_argument(
        "--serial-device",
        default=None,
        help="tty on the board host (default: from the cache, else /dev/ttyACM0)",
    )
    parser.add_argument("--baud", type=int, default=3000000, help="console baud rate")
    parser.add_argument(
        "--arms", default="soft,hwlib,hwstatic,inline", help="comma-separated arms to run"
    )
    args = parser.parse_args()

    if not CACHE_PATH.exists():
        print(
            f"no rig configuration at {CACHE_PATH}; "
            "run scripts/remote_smoke_tui.py --reconfigure first",
            file=sys.stderr,
        )
        return 1
    config = json.loads(CACHE_PATH.read_text())
    ssh_target = config["ssh_target"]
    remote_repo = str(config.get("remote_repo_path", "~/yasos_remote_smoke"))
    device = args.serial_device or config.get("serial_device") or "/dev/ttyACM0"

    suffix = f" {args.iters}" if args.iters else ""
    commands = [f"fpbench-{arm}{suffix}" for arm in args.arms.split(",") if arm]
    commands.append("fpbench-inline --report")

    remote_python = f"{remote_repo}/workdir/venv/bin/python3"
    remote_cmd = f"{remote_python} - {shlex.quote(device)} {args.baud} " + " ".join(
        shlex.quote(c) for c in commands
    )

    ssh = ["ssh"]
    if config.get("ssh_port") and int(config["ssh_port"]) != 22:
        ssh += ["-p", str(config["ssh_port"])]
    if config.get("ssh_identity_file"):
        ssh += ["-i", str(config["ssh_identity_file"])]
    ssh += [ssh_target, remote_cmd]

    completed = subprocess.run(ssh, input=REMOTE_DRIVER, text=True)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
