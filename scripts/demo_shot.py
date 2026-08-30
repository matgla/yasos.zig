#!/usr/bin/env python3
"""Play a scripted terminal take on the board and mirror it into this terminal.

The "live demo" rows of `recording-plan.md` (T10/T12, scene 12) mean typing at
the board on camera: boot, read a source file, compile it with the native tcc,
run it, write a new program in vi, compile and run that one too.  Typed by hand
that is a take you cannot repeat and cannot re-shoot at the same pace.  This
plays the same keystrokes at the same cadence every time, and what ends up on
screen is the *board's own echo* -- the target talking, not a re-enactment.

Where it runs: on the rig that owns the board, because the debug probe is there.
Mirror it into the recorded terminal with

    scripts/demo_shot.sh full            # push + play, screen cleared first

and the board's escape sequences reach the local terminal unchanged, so full
screen apps (`vi` = apps/yasvi over libs/yasos_curses) render normally.

Three properties of this link shape the whole design, all of them established
elsewhere in the tree:

* The console is 3 Mbaud (``CONSOLE_BAUDRATE``, tests/smoke/framework/session.py,
  matched to source/kernel/drivers/uart/uart_driver.zig) and **the debug probe
  drops the occasional host->target byte**.  A drop mid-take is a typo on
  camera, so every character typed at the shell is checked against its echo and
  resent when it never arrives -- what ``write_command()`` does per line, done
  per character.  A resend reads as a half-beat of hesitation, not as a typo.

* **vi probes the terminal size with CPR** (``ESC[999;999H`` then ``ESC[6n``,
  libs/yasos_curses/curses.c ``initscr``) and falls back to 24x80 when nobody
  answers.  Nobody would: the far end of this link is a script.  So the driver
  answers -- with the size of the terminal it is mirroring into, taken from
  ``ssh -t`` -- and strips the query out of the mirror so the local terminal
  does not answer it a second time.

* **vi has to be driven blind** (memory: yasos-tui-smoke-test-technique).  Its
  screen is a flood of repaints, so nothing can be typed-and-verified in there.
  The take is checked afterwards instead, by reading the file back with ``cat``
  and comparing it against what was meant to be typed.  A bad take then says so
  at the end, rather than in the edit three weeks later.

Verdicts go to stderr *after* the take ends, and to ``--report``; the editor
cuts the tail of the clip anyway, and a mid-take verdict line would be visible.

The disassembly beat is offline: the take runs ``hexdump`` over the binary the
board just produced, and

    scripts/demo_shot.py --extract PATH.raw hello.bin

rebuilds that exact binary from the transcript for
``arm-none-eabi-objdump -d``.  The board also prints ``sha256sum`` of the file,
so the frame carries its own proof that the disassembly is of the bytes the
board wrote and not of a host cross-compile of the same source.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import random
import re
import subprocess
import sys
import time


# Matched to source/kernel/drivers/uart/uart_driver.zig; see the note on
# CONSOLE_BAUDRATE in tests/smoke/framework/session.py.
BAUD = 3000000
PORT = "/dev/ttyACM0"

# Two CI runners share this board; the convention is a flock on this path.
LOCK = "/var/lock/rp2350-board.lock"

# An echo cannot legitimately be slow -- the shell echoes as it reads the line --
# so this is an idle deadline, not a budget (session.py ECHO_IDLE_TIMEOUT).
ECHO_TIMEOUT = 0.25

CPR_QUERY = b"\x1b[6n"
PROMPT = "$ "

_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]")


def strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text).replace("\r", "")


class Board:
    """The serial link, mirrored to stdout as it is driven."""

    def __init__(self, ser, out, rows, cols, cps, transcript=None):
        self.ser = ser
        self.out = out
        self.rows = rows
        self.cols = cols
        self.cps = cps
        self.transcript = transcript
        self.window = ""      # everything received, ANSI-stripped, for matching
        self._carry = b""     # a CPR query split across two reads
        self.checks = []      # (name, ok, detail)

    # --- the pump -------------------------------------------------------

    def pump(self, seconds=0.0):
        """Mirror whatever arrives for *seconds*, answering CPR probes."""
        deadline = time.monotonic() + seconds
        while True:
            chunk = self.ser.read(self.ser.in_waiting or 1)
            if chunk:
                self._absorb(chunk)
            if time.monotonic() >= deadline:
                return

    def _absorb(self, chunk: bytes) -> None:
        data = self._carry + chunk
        self._carry = b""

        if CPR_QUERY in data:
            reply = f"\x1b[{self.rows};{self.cols}R".encode()
            for _ in range(data.count(CPR_QUERY)):
                self.ser.write(reply)
            self.ser.flush()
            data = data.replace(CPR_QUERY, b"")

        # Hold back a tail that could still become a CPR query on the next read.
        for k in range(len(CPR_QUERY) - 1, 0, -1):
            if data.endswith(CPR_QUERY[:k]):
                data, self._carry = data[:-k], data[-k:]
                break

        if self.transcript:
            self.transcript.write(data)
            self.transcript.flush()
        self.out.write(data)
        self.out.flush()
        self.window += strip_ansi(data.decode("utf-8", errors="replace"))

    def beat(self, seconds):
        """A deliberate pause, still mirroring.  The take's punctuation."""
        self.pump(seconds)

    # --- waiting --------------------------------------------------------

    def expect(self, needle, timeout=15.0):
        """Wait for *needle*, mirroring meanwhile.  Records no verdict --
        a shot decides which waits are worth failing a take over."""
        mark = len(self.window)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump(0.02)
            if needle in self.window[mark:]:
                return True
        return False

    def wait_prompt(self, timeout=20.0):
        return self.expect(PROMPT, timeout)

    # --- typing ---------------------------------------------------------

    def _send_char(self, ch, verify):
        data = ch.encode("utf-8")
        self.ser.write(data)
        self.ser.flush()
        if not verify:
            return
        mark = len(self.window)
        want = "\n" if ch == "\n" else ch
        deadline = time.monotonic() + ECHO_TIMEOUT
        while time.monotonic() < deadline:
            self.pump(0.004)
            if want in self.window[mark:]:
                return
        # A dropped host->target byte.  Resending is the harness's own recovery;
        # one character late looks like hesitation, a missing one looks like a typo.
        self.ser.write(data)
        self.ser.flush()
        self.pump(0.05)

    def type(self, text, cps=None, verify=True):
        """Type *text* at a human cadence.  No Enter -- that is `press`."""
        step = 1.0 / (cps or self.cps)
        for ch in text:
            self._send_char(ch, verify)
            pause = step * random.uniform(0.55, 1.6)
            if ch in ",;)":
                pause += step * 2.0
            elif ch == " " and random.random() < 0.10:
                pause += step * 3.0
            self.pump(pause)

    def press(self, keys=b"\n", settle=0.0):
        self.ser.write(keys)
        self.ser.flush()
        self.pump(settle)

    def command(self, text, think=0.45, timeout=30.0, cps=None):
        """Type a shell command, run it, and return what it printed.

        Returning the output rather than a bool is what lets a shot assert on
        it: by the time the prompt is back the output is already in the window,
        so a later `expect` for it would wait for a second copy that never
        comes.
        """
        mark = len(self.window)
        self.type(text, cps=cps)
        self.beat(think)
        self.press(b"\n")
        if not self.wait_prompt(timeout):
            self.check(f"`{text}` returned to the prompt", False,
                       f"no prompt within {timeout:g}s")
        return self.window[mark:]

    def resync(self, timeout=4.0):
        """Start from a known state: a prompt, nothing half-typed.

        A take that follows an aborted one can otherwise open with its first
        command being eaten by whatever the last program was reading.
        """
        self.ser.reset_input_buffer()
        self.press(b"\n")
        return self.wait_prompt(timeout)

    # --- checks ---------------------------------------------------------

    def check(self, name, ok, detail=""):
        self.checks.append((name, bool(ok), detail))
        return ok

    def check_seen(self, name, needle, timeout=15.0):
        return self.check(name, self.expect(needle, timeout),
                          f"{needle!r} never appeared")

    # --- board control --------------------------------------------------

    def reset(self, reset_cmd):
        """Reset the target so the take opens on a real boot.

        openocd's own chatter is swallowed: the frame should carry the board's
        boot banner and nothing else.
        """
        self.ser.reset_input_buffer()
        subprocess.run(reset_cmd, shell=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)


# ---------------------------------------------------------------------------
# Shots.  A shot is a function; `--list` enumerates them.
# ---------------------------------------------------------------------------

# What the vi beat types.  Two constraints: it has to fit in about half a minute
# of typing at `--cps`, and what it prints has to be worth holding the frame on
# -- `hello_world.c` already covered "it printed a line".  Both programs here
# draw something out of nested loops over an induction variable, which is the
# shape the video has just spent fifteen minutes explaining, so `-dump-ir` and
# the disassembly beats still have something to point at.
#
# Each program ships the drawing it must produce, generated by the same rule the
# C uses.  A take where the board garbled or dropped a row then fails a check
# here instead of surviving to the edit.

TREE_HEIGHT = 9

TREE = [
    "#include <stdio.h>",
    "",
    "int main(void) {",
    f"  int h = {TREE_HEIGHT};",
    "  for (int i = 1; i <= h; i++) {",
    "    for (int s = h - i; s > 0; s--)",
    "      putchar(' ');",
    "    for (int k = 0; k < 2 * i - 1; k++)",
    "      putchar((i + k) % 5 == 0 ? 'o' : '*');",
    "    putchar('\\n');",
    "  }",
    "  for (int i = 0; i < h - 2; i++)",
    "    putchar(' ');",
    "  printf(\"|||\\n\");",
    "  return 0;",
    "}",
]


def tree_art(h=TREE_HEIGHT):
    rows = [" " * (h - i) + "".join("o" if (i + k) % 5 == 0 else "*"
                                    for k in range(2 * i - 1))
            for i in range(1, h + 1)]
    rows.append(" " * (h - 2) + "|||")
    return rows


# Pascal's triangle mod 2 -- `(i & k) == k` is odd -- so sixteen rows of nested
# loop draw a Sierpinski triangle.  Shorter to type than the tree and the
# stronger picture; the tree is the default because it reads at a glance.
SIERPINSKI = [
    "#include <stdio.h>",
    "",
    "int main(void) {",
    "  for (int i = 0; i < 16; i++) {",
    "    for (int s = 16 - i; s > 0; s--)",
    "      putchar(' ');",
    "    for (int k = 0; k <= i; k++)",
    "      printf((i & k) == k ? \"* \" : \"  \");",
    "    putchar('\\n');",
    "  }",
    "  return 0;",
    "}",
]


def sierpinski_art(n=16):
    return [" " * (n - i) + "".join("* " if (i & k) == k else "  "
                                    for k in range(i + 1))
            for i in range(n)]


PROGRAMS = {
    "tree": (TREE, tree_art()),
    "sierpinski": (SIERPINSKI, sierpinski_art()),
}


def block_in(out, rows):
    """True when *rows* appear as consecutive lines of *out*.

    Consecutive and exact bar trailing blanks, because that is what a drawing
    is: a check for a couple of signature lines would pass a take that lost a
    row in the middle.
    """
    lines = [line.rstrip() for line in out.splitlines()]
    want = [row.rstrip() for row in rows]
    return any(lines[i:i + len(want)] == want
               for i in range(len(lines) - len(want) + 1))


def shot_boot(b, args):
    """Reset, and hold on the boot banner and first prompt."""
    if not args.no_reset:
        b.reset(args.reset_cmd)
    else:
        b.press(b"\n")
    b.check("boot reached the prompt", b.wait_prompt(timeout=40))
    b.beat(1.5)


def shot_hello(b, args):
    """Read a source file on the board, compile it natively, run it.

    /usr/hello_world.c ends in a `scanf`, so the take answers it -- which is
    the better shot anyway: the program is interactive, on the board, live.
    """
    b.command("cat /usr/hello_world.c")
    b.beat(2.5)                      # the viewer reads the program
    b.command("tcc /usr/hello_world.c -o /tmp/hello", timeout=120)
    b.beat(1.0)

    b.type("/tmp/hello")
    b.beat(0.4)
    b.press(b"\n")
    b.check("hello asked for a number", b.expect("provide number", timeout=20))
    b.beat(1.2)
    b.type("42")
    b.beat(0.5)
    b.press(b"\n")
    b.check_seen("hello read the number", "You entered: 42")
    b.wait_prompt(timeout=20)
    b.beat(2.0)


def shot_vi(b, args):
    """Write a program in vi on the board, then compile and run it.

    Which program is `--program`; both draw, so the payoff of the beat is a
    picture the board computed rather than another printed line.

    Driven blind and checked afterwards with `cat`; see the module docstring.
    """
    program, art = PROGRAMS[args.program]

    # vi takes the screen, so no prompt comes back: type the command by hand
    # rather than through command(), which waits for one.
    b.type("vi /tmp/demo.c")
    b.beat(0.4)
    b.press(b"\n")
    b.beat(1.8)                               # initscr, CPR, first paint
    b.press(b"i", settle=0.4)                 # insert mode

    for n, line in enumerate(program):
        b.type(line, verify=False, cps=args.cps)
        if n != len(program) - 1:
            b.press(b"\n", settle=0.12)
    b.beat(0.8)
    b.press(b"\x1b", settle=0.5)              # normal mode
    b.type(":wq", verify=False)
    b.beat(0.3)
    b.press(b"\n")
    b.check("vi exited to the prompt", b.wait_prompt(timeout=20))
    b.beat(1.2)

    got = b.command("cat /tmp/demo.c")
    b.check("the file holds what was typed", "\n".join(program) in got,
            "cat does not show the program as typed -- retake")
    b.beat(1.5)

    b.command("tcc /tmp/demo.c -o /tmp/demo", timeout=120)
    b.beat(0.8)
    out = b.command("/tmp/demo")
    b.check(f"demo drew the {args.program}", block_in(out, art),
            "the drawing the board printed is not the expected one -- retake")
    b.beat(3.0)                      # the picture is the shot: hold on it


def shot_ir(b, args):
    """The compiler showing its own IR -- NEEDS a CONFIG_TCC_DEBUG device tcc.

    Measured 2026-08-29: the shipped device tcc accepts `-dump-ir` and prints
    nothing, because every dump site is inside `#ifdef CONFIG_TCC_DEBUG`
    (source/opt/function_pipeline.c, source/ir/dump.c) and the rootfs build does
    not define it.  The host cross compiler does:

        libs/tinycc/bin/armv8m-tcc -dump-ir demo.c -o /dev/null

    So this beat is either a host insert or a purpose-built device tcc; it is
    deliberately not part of `full`.
    """
    b.command("tcc -dump-ir /tmp/demo.c -o /tmp/demo", timeout=120)
    b.check("the device tcc dumped IR", "IR BEFORE" in b.window,
            "no dump: this tcc is built without CONFIG_TCC_DEBUG")
    b.beat(3.0)


def shot_bytes(b, args):
    """The bytes the board wrote, with a hash so the disassembly can prove it.

    `--extract` turns the hexdump in the transcript back into the binary.
    """
    b.command("sha256sum /tmp/demo", timeout=60)
    b.beat(2.0)
    b.command("hexdump /tmp/demo", timeout=120)
    b.beat(2.0)


def shot_full(b, args):
    """The whole scene-12 arc in one take."""
    shot_boot(b, args)
    shot_hello(b, args)
    b.beat(1.0)
    shot_vi(b, args)
    b.beat(1.0)
    shot_bytes(b, args)      # `ir` is not here on purpose -- see shot_ir


SHOTS = {
    "boot": shot_boot,
    "hello": shot_hello,
    "vi": shot_vi,
    "ir": shot_ir,
    "bytes": shot_bytes,
    "full": shot_full,
}


# ---------------------------------------------------------------------------
# Offline: rebuild the binary from the hexdump in a transcript.
# ---------------------------------------------------------------------------

# apps/hexdump/main.c: "%07x " offset, then up to eight "%04x " little-endian
# halfwords for the 16 bytes it read.
_HEX_RE = re.compile(r"^([0-9a-f]{7}) ((?:[0-9a-f]{4} )+)$")


# YaffHeader, libs/tinycc/source/obj/tccyaff.h -- packed, so these are byte
# offsets into the file the board wrote: the code length and where .text starts.
YAFF_CODE_LENGTH_OFF = 8
YAFF_TEXT_OFF = 70


def disasm(bin_path, vma=0):
    """Disassemble the .text of a YAFF module the board produced."""
    import struct
    data = open(bin_path, "rb").read()
    if data[:4] != b"YAFF":
        print(f"{bin_path} is not a YAFF module", file=sys.stderr)
        return 1
    code_len = struct.unpack_from("<I", data, YAFF_CODE_LENGTH_OFF)[0]
    text_off = struct.unpack_from("<H", data, YAFF_TEXT_OFF)[0]
    text_path = bin_path + ".text"
    open(text_path, "wb").write(data[text_off:text_off + code_len])
    print(f"{code_len} bytes of .text at file offset 0x{text_off:x}", file=sys.stderr)
    return subprocess.run([
        "arm-none-eabi-objdump", "-D", "-b", "binary", "-m", "arm",
        "-M", "force-thumb", f"--adjust-vma={vma}", text_path,
    ]).returncode


def extract(raw_path, out_path):
    text = strip_ansi(open(raw_path, "rb").read().decode("utf-8", errors="replace"))
    blob = bytearray()
    seen = 0
    for line in text.splitlines():
        m = _HEX_RE.match(line.strip() + " ")
        if not m:
            continue
        offset = int(m.group(1), 16)
        if offset != len(blob):
            if offset < len(blob):      # a second hexdump in the same take
                continue
            print(f"gap at 0x{offset:x} (have {len(blob)} bytes) -- transcript "
                  f"is missing lines", file=sys.stderr)
            return 1
        for half in m.group(2).split():
            blob += int(half, 16).to_bytes(2, "little")
        seen += 1
    if not seen:
        print("no hexdump lines in the transcript", file=sys.stderr)
        return 1
    open(out_path, "wb").write(blob)
    # The last read can be odd-length; hexdump zero-fills its buffer, so the
    # tail may carry one padding byte.  Say so rather than guessing.
    print(f"{out_path}: {len(blob)} bytes from {seen} lines "
          f"(tail may hold one zero pad byte)", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------


def terminal_size(default_rows, default_cols):
    try:
        size = os.get_terminal_size(sys.stdout.fileno())
        return size.lines, size.columns
    except OSError:
        return default_rows, default_cols


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("shot", nargs="?", help="which take to play")
    p.add_argument("--list", action="store_true", help="list the shots")
    p.add_argument("--extract", nargs=2, metavar=("TRANSCRIPT", "OUT"),
                   help="rebuild the hexdumped binary from a transcript")
    p.add_argument("--disasm", metavar="BIN",
                   help="disassemble the .text of a YAFF module (from --extract)")
    p.add_argument("--vma", default="0", help="address to disassemble at, e.g. "
                   "the one the loader printed for the module")
    p.add_argument("--port", default=PORT)
    p.add_argument("--baud", type=int, default=BAUD)
    p.add_argument("--cps", type=float, default=16.0,
                   help="characters per second (default 16, reads as unhurried)")
    p.add_argument("--program", default="tree", choices=sorted(PROGRAMS),
                   help="what the vi shot types (default: tree)")
    p.add_argument("--size", metavar="ROWSxCOLS",
                   help="size to report to vi (default: this terminal's)")
    p.add_argument("--transcript", metavar="PATH",
                   help="write everything the board sent, for --extract")
    p.add_argument("--report", metavar="PATH", help="write the verdicts here too")
    p.add_argument("--seed", type=int, default=7,
                   help="typing jitter seed; same seed, same cadence")
    p.add_argument("--no-clear", action="store_true")
    p.add_argument("--no-reset", action="store_true")
    p.add_argument("--no-lock", action="store_true")
    p.add_argument("--reset-cmd",
                   default=os.path.expanduser("~/yasos_remote_smoke/tests/smoke/reset_target.sh"))
    args = p.parse_args()

    if args.list:
        for name, fn in SHOTS.items():
            print(f"{name:8} {(fn.__doc__ or '').splitlines()[0]}")
        for name, (program, art) in sorted(PROGRAMS.items()):
            chars = sum(len(line) + 1 for line in program)
            print(f"--program {name}: {len(program)} lines, {chars} keystrokes, "
                  f"~{chars * 1.1 / 16:.0f}s at 16 cps")
        return 0
    if args.extract:
        return extract(*args.extract)
    if args.disasm:
        return disasm(args.disasm, int(args.vma, 0))
    if not args.shot or args.shot not in SHOTS:
        p.error(f"pick a shot: {', '.join(SHOTS)}")

    import serial   # only the play path needs it; --extract runs on any host

    random.seed(args.seed)

    lock_fd = None
    if not args.no_lock:
        lock_fd = os.open(LOCK, os.O_RDWR | os.O_CREAT, 0o666)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print(f"{LOCK} is held -- a smoke run has the board", file=sys.stderr)
            return 2

    rows, cols = terminal_size(24, 80)
    if args.size:
        rows, cols = (int(v) for v in args.size.lower().split("x"))

    transcript = open(args.transcript, "wb") if args.transcript else None
    ser = serial.Serial(args.port, args.baud, timeout=0.02)
    board = Board(ser, sys.stdout.buffer, rows, cols, args.cps, transcript)

    # Before the screen is cleared, so its noise never reaches the take.
    board.resync()

    if not args.no_clear:
        sys.stdout.write("\x1b[2J\x1b[H")
        sys.stdout.flush()

    try:
        SHOTS[args.shot](board, args)
    except KeyboardInterrupt:
        board.check("take completed", False, "interrupted")
    finally:
        board.pump(0.3)
        ser.close()
        if transcript:
            transcript.close()

    failed = [c for c in board.checks if not c[1]]
    lines = [f"{'ok  ' if ok else 'FAIL'} {name}" + (f" -- {detail}" if detail and not ok else "")
             for name, ok, detail in board.checks]
    lines.append(f"{len(board.checks) - len(failed)}/{len(board.checks)} checks passed"
                 + ("" if not failed else "  <-- RETAKE"))
    report = "\n".join(lines)
    print("\n" + report, file=sys.stderr)
    if args.report:
        open(args.report, "w").write(report + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
