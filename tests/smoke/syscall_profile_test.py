"""What the syscall path itself costs, measured from the caller.

`io_profile_test.py` reads the kernel's own per-process `sysprof` line, which
times from the SVC entry stamp to the end of the handler. That window answers
"which handler is slow" and structurally cannot answer "what does a call cost":
it stops before the return trampoline, and on this kernel a non-fast syscall
returns through a *second* SVC with a second exception entry and return.

So this drives `syscallbench` instead, which times complete round trips from
user code and reports the differences that isolate each part of the path (see
apps/syscallbench/main.c for why each arm exists):

    trampoline_ns   the second exception round trip a non-fast syscall pays,
                    over a fast-path call doing identical handler work
    fp_tax_fast_ns  eager FP stacking across one entry + one return
    fp_tax_slow_ns  the same across the trampoline's two of each

Measurements, not assertions -- they print and skip rather than fail, so a full
suite run neither pays for them nor can be failed by them:

    scripts/remote_smoke_tui.py --profile --pytest-args \\
        "tests/smoke/syscall_profile_test.py -m measure -s"

The absolute numbers need real hardware. QEMU's Cortex-M models advance no
DWT_CYCCNT and model neither exception-entry cost nor pipeline flushes nor
PSRAM/XIP stack latency, which is precisely what this path is made of; the
kernel now says so itself by tagging its reports `cyc=off`.
"""

import os
import re

import pytest

from .conftest import session_key


pytestmark = pytest.mark.measure


# syscallbench emits one space-separated key=value line per arm:
#   arm=close_bad ns=2140 net_ns=2015 path=trampoline
_ARM_RE = re.compile(
    r"^arm=(?P<name>\w+)\s+ns=(?P<ns>\d+)\s*(?:net_ns=(?P<net_ns>-?\d+))?"
    r"(?:\s+path=(?P<path>\w+))?(?:\s+fpu=(?P<fpu>\w+))?\s*$"
)
_DERIVED_RE = re.compile(
    r"^derived:\s+trampoline_ns=(?P<trampoline>-?\d+)\s+"
    r"fp_tax_fast_ns=(?P<fp_fast>-?\d+)\s+fp_tax_slow_ns=(?P<fp_slow>-?\d+)\s+"
    r"handler_lseek_ns=(?P<handler_lseek>-?\d+)\s*$"
)

# Iterations per arm. The default in the app is tuned for hardware; a slow or
# emulated target can be dialled down without touching the binary.
ITERS = os.environ.get("YASOS_SMOKE_SYSCALLBENCH_ITERS", "")

# Idle timeout, not a deadline. Seven arms x TRIALS x ITERS calls; on the rig
# the whole program is a few seconds, and a regression makes it slower rather
# than silent.
BENCH_TIMEOUT = float(os.environ.get("YASOS_SMOKE_SYSCALLBENCH_TIMEOUT", "180"))


def _run(session):
    command = "syscallbench" + (f" {ITERS}" if ITERS else "")
    with session.timeout(BENCH_TIMEOUT):
        session.write_command(command)
        return session.wait_for_prompt_except_logs()


def test_syscall_path_cost(request):
    session = request.node.stash[session_key]
    lines = _run(session)

    arms = {}
    derived = None
    for line in lines:
        stripped = line.strip()
        match = _ARM_RE.match(stripped)
        if match:
            arms[match.group("name")] = {
                "ns": int(match.group("ns")),
                "net_ns": int(match.group("net_ns") or 0),
                "path": match.group("path") or "",
                "fpu": match.group("fpu") or "",
            }
            continue
        match = _DERIVED_RE.match(stripped)
        if match:
            derived = {key: int(value) for key, value in match.groupdict().items()}

    if not arms:
        # Most likely an image built before the app existed, or a rootfs that
        # was not rebuilt. Say which, rather than failing a measurement test.
        pytest.skip(
            "syscallbench produced no arm= lines -- is it in the rootfs? "
            f"output tail: {[line.strip() for line in lines[-5:]]}"
        )

    print("\n  syscall round-trip cost (per call, loop overhead removed):")
    for name, arm in arms.items():
        if name in ("loop", "fp_loop"):
            print(f"    {name:<16} {arm['ns']:>7} ns   (scaffolding, subtracted below)")
            continue
        tags = " ".join(tag for tag in (arm["path"], arm["fpu"] and "fpu=live") if tag)
        print(f"    {name:<16} {arm['net_ns']:>7} ns   {tags}")

    if derived is None:
        pytest.skip("syscallbench printed no derived: line")

    fast = arms.get("getpid", {}).get("net_ns", 0)
    print("\n  what the path costs:")
    print(f"    fast-path call            {fast:>7} ns   1 exception entry + 1 return")
    print(f"    + trampoline              {derived['trampoline']:>7} ns   the second entry + return")
    print(f"    + eager FP stacking, fast {derived['fp_fast']:>7} ns   s0-s15 + FPSCR, 2 transitions")
    print(f"    + eager FP stacking, slow {derived['fp_slow']:>7} ns   4 transitions")
    print(f"    lseek handler body        {derived['handler_lseek']:>7} ns   not addressable by dispatch")

    if fast > 0:
        print(
            f"\n  a trampoline syscall costs {(fast + derived['trampoline']) / fast:.2f}x "
            "a fast-path one before any handler work."
        )
