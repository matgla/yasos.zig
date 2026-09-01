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

The ``width`` shot is scene 13's argument done live rather than drawn: two
kernels written in *inline assembly*, typed into vi, compiled by the board's own
tcc and then run under ``time`` (apps/time), which exists for this beat.  Both
print the same checksum and one of them takes about twice as long -- the shorter
one.  The program is ``scripts/demo/div10.c``, read at take time so that what is
typed on camera is the file that compiles.

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
import contextlib
import fcntl
import os
import pty
import random
import re
import select
import struct
import subprocess
import sys
import termios
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

    def __init__(self, ser, out, rows, cols, cps, transcript=None,
                 prompt=PROMPT):
        self.ser = ser
        # What "back at the prompt" looks like on this link.  The board's shell
        # ends its prompt in `$ `, which is short enough to appear inside a
        # program's own output -- harmless over serial, where the only thing
        # talking is the shell, and not harmless at all on a host take, where
        # the thing being driven prints paths and shell snippets of its own.
        # So it is per-link, and a shot that drives a *second* prompt (gdb's)
        # sets it for the duration.
        self.prompt = prompt
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
        return self.expect(self.prompt, timeout)

    @contextlib.contextmanager
    def at(self, prompt):
        """Drive a different prompt for a while -- gdb's, inside a take."""
        was, self.prompt = self.prompt, prompt
        try:
            yield self
        finally:
            self.prompt = was

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


class Shell:
    """A shell on *this* machine, in a pty, wearing the serial link's interface.

    `Board` only ever asks its link for five things -- `read`, `in_waiting`,
    `write`, `flush`, `reset_input_buffer` -- so a pty that answers those is
    driven by the same typist that drives the board, and every beat, echo
    check, `expect`, transcript and verdict above works here unchanged.

    Which is the point of doing it this way.  The board takes are the *target*
    talking; the rig takes are about the other half of the loop -- what it
    costs, from this desk, to get code onto a board that is in another room --
    and that half has no serial port in it at all.  It is `remote_smoke_tui.py`
    building here, rsyncing to the Pi, flashing over SWD and attaching gdb, and
    the only honest way to film it is to run it.

    Three things this deliberately does not inherit from the serial link:

    * **No echo-resend.**  A pty echoes what is written to it in the same
      breath, so `_send_char`'s verify loop is satisfied on its first pump and
      the resend path never fires.  Left switched on regardless: it costs one
      already-satisfied comparison per character and it means one typist, not
      two.

    * **No CPR answering is needed** -- but it still happens, and it has to.
      `--connect` puts the *board's* console on this pty, so a full-screen
      program on the target queries the size through it, and `Board._absorb`
      answers with the size this terminal really is.

    * **No board lock.**  The runner takes the board itself; what this checks
      instead, before a take starts, is that nothing else already holds it.
    """

    #: A prompt long enough that it cannot turn up inside a tool's own output.
    #: `$ ` alone appears in half the shell snippets `remote_smoke_tui` prints
    #: when it explains itself, and a take that mistakes one of those for the
    #: prompt walks into the next command while the flash is still running.
    PS1 = "yasos.zig $ "

    def __init__(self, rows, cols, cwd=None, ps1=PS1):
        self.rows, self.cols = rows, cols
        self.closed = False
        self.pid, self.fd = pty.fork()
        if self.pid == 0:                                   # child
            os.chdir(cwd or os.getcwd())
            env = dict(os.environ, PS1=ps1, LINES=str(rows), COLUMNS=str(cols),
                       # A pager that takes the screen mid-take is a take
                       # nobody can finish: the typist is typing at a shell
                       # that is no longer there, and `less` waits for a key
                       # the script has no reason to send.
                       PAGER="cat", GIT_PAGER="cat")
            env.setdefault("TERM", "xterm-256color")
            # Both of these would repaint the prompt with something of their
            # own, and one of them (a git-aware PROMPT_COMMAND) would put a
            # branch name on camera that changes between takes.
            env.pop("PROMPT_COMMAND", None)
            env.pop("BASH_ENV", None)
            os.execvpe("bash", ["bash", "--norc", "--noprofile", "-i"], env)
            os._exit(127)                                   # unreachable
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))
        # Bash 5.1 turns bracketed paste on by default, which wraps everything
        # the typist sends in `ESC[200~`/`ESC[201~`.  Invisible on camera and
        # noise in the transcript -- and the transcript is the artifact a bad
        # take is diagnosed from.  Written rather than typed, and before the
        # screen is cleared, so it is not part of the take.
        os.write(self.fd, b"bind 'set enable-bracketed-paste off' 2>/dev/null\n")

    # --- the five calls a link has --------------------------------------

    @property
    def in_waiting(self):
        return 4096 if select.select([self.fd], [], [], 0)[0] else 0

    def read(self, size=1):
        """Whatever is there, or nothing -- never a block.

        `Board.pump` reads `in_waiting or 1`, which on a serial port with a
        timeout returns empty when the line is quiet.  A pty read would block
        there forever and the take would stop dead on the first silence, so the
        timeout lives here instead: 20 ms is a pump granularity fine enough
        that typing still lands at the cadence it was asked for.
        """
        if self.closed or not select.select([self.fd], [], [], 0.02)[0]:
            return b""
        try:
            data = os.read(self.fd, max(1, size))
        except OSError:                                     # the shell exited
            data = b""
        if not data:
            self.closed = True
        return data

    def write(self, data):
        if not self.closed:
            os.write(self.fd, data)

    def flush(self):
        pass

    def reset_input_buffer(self):
        while not self.closed and select.select([self.fd], [], [], 0)[0]:
            if not self.read(4096):
                break

    def close(self):
        self.closed = True
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            pass


def rig_is_idle(rig, timeout=10.0):
    """Is anything already holding the board?

    A manual run takes no `flock` (memory: yasos-remote-smoke-board-recovery),
    so starting a take while a smoke run is mid-flight resets the target out
    from under it and ruins both.  Cheap to ask, so it is asked every time.
    """
    try:
        done = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", f"-o", f"ConnectTimeout={int(timeout)}",
             rig, 'pgrep -a "pytest|openocd|arm-none-eabi-gdb" || true'],
            capture_output=True, text=True, timeout=timeout + 5)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return False, f"could not reach {rig}: {exc}"
    busy = [l for l in done.stdout.splitlines() if l.strip()]
    return (not busy), ("\n".join(busy) if busy else "")


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


def write_in_vi(b, args, path, program):
    """Type *program* into vi at *path*, then read it back and check it.

    Driven blind and checked afterwards; see the module docstring.  The check
    is the whole program as consecutive lines rather than a signature line or
    two: a take that dropped a character in the middle of a listing is a take
    that compiles something the camera did not show.
    """
    # `vi` on a file that already exists opens it *with the old program in it*
    # and types the new one in at the top, and the result is a doubled file
    # whose compile fails on camera -- while every check below still passes:
    # `cat` finds the program as consecutive lines inside the doubled file, and
    # the binary the previous take built is still there to run.  Seen on
    # 2026-08-31, on a take that reported 3/3.  Removing both first is what
    # makes this a retake rather than a one-shot; takes/tinycc/width.take
    # already does the same thing for the same reason.
    b.command(f"rm -f {path} {os.path.splitext(path)[0]}")

    # vi takes the screen, so no prompt comes back: type the command by hand
    # rather than through command(), which waits for one.
    b.type(f"vi {path}")
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

    got = b.command(f"cat {path}", timeout=60)
    b.check("the file holds what was typed", "\n".join(program) in got,
            "cat does not show the program as typed -- retake")
    b.beat(1.5)


def shot_vi(b, args):
    """Write a program in vi on the board, then compile and run it.

    Which program is `--program`; both draw, so the payoff of the beat is a
    picture the board computed rather than another printed line.
    """
    program, art = PROGRAMS[args.program]
    write_in_vi(b, args, "/tmp/demo.c", program)

    b.command("tcc /tmp/demo.c -o /tmp/demo", timeout=120)
    b.beat(0.8)
    out = b.command("/tmp/demo")
    b.check(f"demo drew the {args.program}", block_in(out, art),
            "the drawing the board printed is not the expected one -- retake")
    b.beat(3.0)                      # the picture is the shot: hold on it


# ---------------------------------------------------------------------------
# The width beat: two kernels, one answer, two times.
# ---------------------------------------------------------------------------

# The program the `width` shot types, kept as a real .c file rather than a list
# of strings here.  It is compiled three ways -- by the board during the take,
# by `armv8m-tcc` when scene 13's encodings are checked against it, and by the
# video_scripter typist take, which types it with `from=` -- and three copies of
# a listing that has to agree instruction for instruction is three chances for
# it not to.
DIV10_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "demo", "div10.c")

# What div10.c holds, spelled out so the checksum below can be *derived* rather
# than remembered.  Every one of them is checked against the source before the
# take starts, so editing the C and not this is a loud failure on the bench
# instead of a "MISMATCH" on camera.
DIV10_N = 1024                     # elements in the array
DIV10_PASSES = 60000               # times the whole array is divided
DIV10_LCG = (1103515245, 12345)    # what fills it

# The two arms compile to `udiv r5, r4, r3` and to `umull`/`lsrs #3`, which is
# floor(x / 10) both times: (x * 0xCCCCCCCD) >> 35 == x / 10 for every uint32.
# So they have to print one number, and the shot checks that they do before it
# reports a ratio -- a faster sequence that computes something else is not a
# faster sequence.
_REAL_RE = re.compile(r"real\s+(\d+)\.(\d+)\s*s")
_SUM_RE = re.compile(r"^(udiv|recip)\s+(\d+)\s*$", re.M)


def div10_source():
    """The demo program, checked against the constants this module derives
    the expected checksum from."""
    text = open(DIV10_PATH, encoding="utf-8").read()
    for want in (DIV10_N, DIV10_PASSES) + DIV10_LCG:
        if str(want) not in text:
            raise SystemExit(f"{DIV10_PATH} no longer holds {want} -- "
                             f"update DIV10_* in {os.path.basename(__file__)}")
    return text


def div10_checksum():
    """What both arms must print: the same arithmetic div10.c does, in Python.

    Derived rather than observed, so a take that prints something else has
    found a real disagreement instead of catching up with a stale constant.
    """
    seed, mask = 1, 0xFFFFFFFF
    per_pass = 0
    for _ in range(DIV10_N):
        seed = (seed * DIV10_LCG[0] + DIV10_LCG[1]) & mask
        per_pass = (per_pass + seed // 10) & mask
    return (per_pass * DIV10_PASSES) & mask


def timing_in(out):
    """The seconds `time` reported, or None.  It prints to stderr, which is the
    same console here."""
    found = _REAL_RE.search(out)
    if not found:
        return None
    return int(found.group(1)) + int(found.group(2)) / 10 ** len(found.group(2))


def checksum_in(out):
    found = _SUM_RE.search(out)
    return int(found.group(2)) if found else None


def shot_width(b, args):
    """Type two inline-asm kernels, compile them on the board, and time both.

    This is scene 13's claim done live: the arm with *fewer bytes and fewer
    instructions* is the slower one.  Everything that makes it an experiment
    rather than an assertion is in the shape of the take:

    * **One binary, two arms.**  `div10 udiv` and `div10 recip` are the same
      file, so the loader, the image size and the exec cost are constants and
      the only thing that differs between the two numbers on screen is which
      three instructions the inner loop runs.
    * **The checksums are compared before the times are.**  Both kernels
      compute floor(x/10) and must print one number; the shot fails the take
      if they do not, and says so rather than reporting a ratio between two
      different programs.
    * **The board's own tcc assembles the listing.**  The bytes it chooses for
      the two loops -- `f851 4b04 / fbb4 f5f3 / 1940` and
      `f851 4b04 / fba4 5603 / 08f6 / 1980`, 10 bytes against 12 -- are the
      encodings the card counts.

    The ratio here is nearer 2x than the card's 2.25x, and for a stated reason:
    `libs/tinycc/tests/benchmarks/width_kernels.S` is 4x-unrolled with
    interrupts off, so the loop's own `subs`/`bne` is amortised away.  This loop
    pays it every element, which lifts both arms by the same constant and pulls
    the ratio down.  Same direction, smaller number, honest either way.
    """
    program = div10_source().splitlines()
    write_in_vi(b, args, "/tmp/div10.c", program)

    b.command("tcc -O2 /tmp/div10.c -o /tmp/div10", timeout=300)
    b.beat(1.0)

    want = div10_checksum()
    seen = {}
    for arm in ("udiv", "recip"):
        out = b.command(f"time /tmp/div10 {arm}", timeout=300)
        seen[arm] = (checksum_in(out), timing_in(out))
        b.check(f"{arm} printed a time", seen[arm][1] is not None,
                "no `real` line -- is `time` in this rootfs?")
        b.check(f"{arm} computed floor(x/10)", seen[arm][0] == want,
                f"checksum {seen[arm][0]}, expected {want}")
        b.beat(2.0)

    slow, fast = seen["udiv"][1], seen["recip"][1]
    if slow and fast:
        b.check("the shorter arm is the slower one", slow > fast,
                f"udiv {slow:.3f}s, recip {fast:.3f}s -- no gap to show")
        b.checks.append((f"udiv/recip = {slow / fast:.2f}x "
                         f"({slow:.3f}s against {fast:.3f}s)", True, ""))
    b.beat(3.0)                      # the two numbers are the shot: hold


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


# ---------------------------------------------------------------------------
# Rig shots.  These drive a shell on *this* machine, not the board -- the
# subject is the loop, not the target.  `RIG_SHOTS` picks the transport.
# ---------------------------------------------------------------------------

#: What the gdb beat asks the board to do while gdb is watching.  A tcc compile
#: rather than `hello_world`: it is the workload every fault in this project has
#: ever come out of, and it runs long enough that a halt lands somewhere
#: interesting rather than in the idle loop.
RIG_CMD = "tcc /usr/hello_world.c -o /tmp/hello"

#: gdb's prompt, for the stretch of the take where gdb is the thing being typed
#: at.  `Board.at()` swaps it back afterwards.
GDB_PROMPT = "(gdb) "


def shot_rig_dry(b, args):
    """The typist, proving itself -- no board, no rig, nothing to lose.

    Worth having as a shot rather than as a one-off: it is what you run when a
    take came out wrong and the question is whether the harness or the rig was
    at fault, and it answers that in eight seconds without touching the board.
    """
    b.beat(0.8)
    out = b.command("git -c color.ui=always log --oneline -3")
    b.check("the shell answered", out.strip() != "", "nothing came back")
    b.beat(1.2)
    b.command("ls scripts/remote_smoke_tui.py")
    b.beat(1.5)


def shot_rig_flash(b, args):
    """Build here, sync to the Pi, flash the board over SWD -- one command.

    The three steps the runner prints are the three claims of the scene: the
    build is local, the artifacts travel, and the thing that writes flash is at
    the other end of the wire.  Each is checked, because the whole point of
    filming this rather than drawing it is that it is the real run -- and a
    take where the flash quietly did not happen is worth failing here rather
    than in the edit.
    """
    b.beat(1.0)
    out = b.command(f"./scripts/remote_smoke_tui.py --flash-only",
                    timeout=args.rig_timeout)
    b.check("built locally", "Building local artifacts" in out,
            "no build step in the output")
    b.check("artifacts reached the rig", "Uploading artifacts" in out,
            "nothing was uploaded")
    b.check("the run finished", "completed successfully" in out,
            "the runner did not report success -- check the tail of the take")
    b.beat(3.0)


def shot_rig_gdb(b, args):
    """The debug half: reset, run one command on the target, attach gdb to it.

    `--gdb-debug` is the flag this project actually debugs with -- it resets
    the board, sends the command over serial, captures the loader log,
    reset-halts and brings gdb up with the kernel's symbols already loaded.
    On camera that is the whole argument for the rig in about a minute: the
    board is in another room and there is still a stack trace on this screen.

    The gdb half is typed at gdb's own prompt, which is what `Board.at` is for.
    `quit` on a live inferior asks for confirmation, so the `y` is part of the
    take rather than something the editor has to explain.
    """
    b.beat(1.0)
    b.type(f"./scripts/remote_smoke_tui.py --gdb-debug --cmd '{args.rig_cmd}'")
    b.beat(0.6)
    b.press(b"\n")

    b.check("openocd came up", b.expect("OpenOCD ready", args.rig_timeout),
            "openocd never announced itself -- probe wedged?")
    b.check("gdb attached", b.expect(GDB_PROMPT, 240.0),
            "no gdb prompt")
    b.beat(2.0)

    with b.at(GDB_PROMPT):
        b.command("info threads", timeout=60)
        b.beat(1.5)

        # `--gdb-debug` reset-HALTS before it hands over, so the core is parked
        # on the reset vector and a backtrace at this point is one frame of
        # `0x00000088 in ??` -- measured 2026-09-01, and useless on camera: the
        # claim of the scene is that a board in another room can be stopped and
        # read, and `??` demonstrates the opposite.  So the take runs it to a
        # symbol first.  `main` is the kernel's own entry (`arm-none-eabi-nm
        # zig-out/bin/yasos_kernel`), it is always reached, and it is reached
        # within a second of the core being let go.
        b.command(f"break {args.gdb_break}", timeout=60)
        b.beat(1.0)
        b.command("continue", timeout=120)
        b.check("stopped in the kernel, with symbols",
                args.gdb_break in b.window[-4000:] and "??" not in b.window[-400:],
                f"never reached {args.gdb_break} -- wrong symbols flashed?")
        b.beat(2.0)
        b.command("bt", timeout=60)
        b.beat(2.5)
        b.command("info registers pc sp", timeout=60)
        b.beat(2.5)
        b.type("quit")
        b.press(b"\n")
        b.beat(1.0)
        b.press(b"y\n")            # "A debugging session is active... Quit anyway?"

    b.check("back at the shell", b.wait_prompt(60.0), "gdb did not let go")
    b.beat(2.0)


def shot_rig_full(b, args):
    """Flash, then debug -- the whole rig arc in one take."""
    shot_rig_flash(b, args)
    b.beat(2.0)
    shot_rig_gdb(b, args)


RIG_SHOTS = {
    "rig_dry": shot_rig_dry,
    "rig_flash": shot_rig_flash,
    "rig_gdb": shot_rig_gdb,
    "rig_full": shot_rig_full,
}


SHOTS = {
    "boot": shot_boot,
    "hello": shot_hello,
    "vi": shot_vi,
    "ir": shot_ir,
    "bytes": shot_bytes,
    "width": shot_width,
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
    p.add_argument("--rig", default=os.environ.get("YASOS_RIG",
                                                    "mateusz@192.168.0.113"),
                   help="the host that owns the board; a rig shot refuses to "
                        "start while something there already holds it")
    p.add_argument("--rig-cmd", default=RIG_CMD,
                   help="what the gdb take asks the target to run")
    p.add_argument("--gdb-break", default="main",
                   help="symbol the gdb take runs to before it asks for a "
                        "backtrace; a reset-halted core has none")
    p.add_argument("--rig-timeout", type=float, default=1200.0,
                   help="how long a rig shot will wait for one command; a cold "
                        "flash is minutes, not seconds")
    p.add_argument("--cwd", default=None,
                   help="where the rig take's shell starts (default: here)")
    p.add_argument("--reset-cmd",
                   default=os.path.expanduser("~/yasos_remote_smoke/tests/smoke/reset_target.sh"))
    args = p.parse_args()

    if args.list:
        for name, fn in {**SHOTS, **RIG_SHOTS}.items():
            where = "rig" if name in RIG_SHOTS else "board"
            print(f"{name:10} [{where:5}] {(fn.__doc__ or '').splitlines()[0]}")
        for name, (program, art) in sorted(PROGRAMS.items()):
            chars = sum(len(line) + 1 for line in program)
            print(f"--program {name}: {len(program)} lines, {chars} keystrokes, "
                  f"~{chars * 1.1 / 16:.0f}s at 16 cps")
        return 0
    if args.extract:
        return extract(*args.extract)
    if args.disasm:
        return disasm(args.disasm, int(args.vma, 0))
    if not args.shot or args.shot not in {**SHOTS, **RIG_SHOTS}:
        p.error(f"pick a shot: {', '.join({**SHOTS, **RIG_SHOTS})}")

    rig_shot = args.shot in RIG_SHOTS
    random.seed(args.seed)

    lock_fd = None
    if rig_shot:
        # The board is taken by the runner this take is filming, so there is
        # nothing here to lock -- but there is something to refuse over.
        if args.shot != "rig_dry" and not args.no_lock:
            idle, busy = rig_is_idle(args.rig)
            if not idle:
                print(f"{args.rig} is busy -- not starting a take:\n{busy}",
                      file=sys.stderr)
                return 2
    elif not args.no_lock:
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
    if rig_shot:
        ser = Shell(rows, cols, cwd=args.cwd)
        prompt = Shell.PS1
    else:
        import serial   # only the board path needs it; --extract runs anywhere
        ser = serial.Serial(args.port, args.baud, timeout=0.02)
        prompt = PROMPT
    board = Board(ser, sys.stdout.buffer, rows, cols, args.cps, transcript,
                  prompt=prompt)

    # Before the screen is cleared, so its noise never reaches the take -- and
    # on a rig take that noise is bash's first prompt, which arrives whenever
    # it arrives and would otherwise be the first thing on camera.
    board.resync()

    if not args.no_clear:
        if rig_shot:
            # Ctrl-L rather than writing the escape ourselves: the escape wipes
            # the prompt bash has *already* drawn, and the take then opens on a
            # command being typed at column zero with nothing in front of it.
            # Ctrl-L makes the shell clear and redraw, so the first frame is a
            # prompt, which is what a terminal take has to open on.
            board.press(b"\x0c", settle=0.35)
        else:
            sys.stdout.write("\x1b[2J\x1b[H")
            sys.stdout.flush()

    try:
        {**SHOTS, **RIG_SHOTS}[args.shot](board, args)
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
