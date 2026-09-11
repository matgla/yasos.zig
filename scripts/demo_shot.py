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

The ``xip`` shot is scene 8's premise counted rather than asserted: the board
reads its own XIP cache counters out of ``/proc/xip`` either side of a
``tcc /usr/hello_world.c`` compile, five times, plus a control window that
prices the reads themselves.  Both reads live *inside* the compile's command
line, because two reads typed separately put several seconds of shell echo in
the window.  The verdicts carry the derived table -- accesses, misses, hit rate,
and an upper bound on the stall -- and say so when it disagrees with the
figures on the scene card.

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
import shutil
import subprocess
import sys
import tempfile
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
                 prompt=PROMPT, keylog=None):
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
        # The click track is synthesised afterwards from when each key was
        # struck, never played during the take: the stage has no audio sink and
        # an audio server's timing would drift against a five-minute picture.
        # `utilities/keyclack.py` in the video repo reads exactly this format --
        # a `# start <epoch>` line, then `<seconds since start>\t<kind>` per key
        # -- and the *kind* rather than the character, because what a key sounds
        # like is a fact about its size and its stabiliser and the take's own
        # text has no business in a file that exists to be turned into noise.
        self._keylog = None
        self._keylog_zero = None
        if keylog:
            self._keylog = open(keylog, "w", encoding="utf-8", buffering=1)
            self._keylog_zero = time.time()
            self._keylog.write(f"# start {self._keylog_zero:.6f}\n")

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

    def keylog_write(self, sent):
        """One line per key struck, for the click track (no-op without a log).

        Timed at the moment the byte goes out on the wire, which is within a
        millisecond or two of when the board echoes it back and the character
        appears on screen -- so the clicks land on the picture, not beside it.
        """
        if not self._keylog:
            return
        for char in sent:
            if char in ("\r", "\n"):
                kind = "enter"
            elif char == " ":
                kind = "space"
            elif char in ("\x7f", "\b"):
                kind = "back"
            elif char == "\t":
                kind = "tab"
            elif char.isupper() or char in '~!@#$%^&*()_+{}|:"<>?':
                kind = "shift"
            elif char.isprintable():
                kind = "key"
            else:
                continue        # control bytes are not keys anybody pressed
            self._keylog.write(
                f"{time.time() - self._keylog_zero:.6f}\t{kind}\n")

    def keylog_close(self):
        if self._keylog:
            self._keylog.close()
            self._keylog = None

    def _send_char(self, ch, verify):
        self.keylog_write(ch)
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
        # Enter and Escape go out here rather than through `type`, and Enter is
        # the one key a listener actually expects to hear at the end of a line.
        self.keylog_write(keys.decode("utf-8", "ignore"))
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


#: What a filmed zsh is configured with.  Written into a throwaway ZDOTDIR per
#: take rather than read from the user's own dotfiles, for the same reason the
#: bash path passes `--norc --noprofile`: a take has to look the same on
#: anybody's machine, and a prompt carrying a git branch would put a different
#: string on camera every week.
#:
#: The highlight styles name COLOURS rather than give hex, deliberately -- the
#: terminal's sixteen are generated from the project's `visual_style.json`
#: (video repo, `utilities/take-backdrop.py`), so `fg=green` is whatever green
#: that project chose.  The shell then follows the palette without knowing it
#: exists, which is the same trick `PS1_INK` plays for bash.
ZSHRC = r"""
unsetopt GLOBAL_RCS
PROMPT=$'\n%B%F{blue}yasos.zig%f%b %F{yellow}$%f '
# zsh marks a command whose output did not end in a newline with an inverse
# `%` and a bar of blanks to the width of the terminal.  Correct, and on camera
# it is a white stripe across the frame after anything that forgets its final
# newline.
unsetopt PROMPT_SP
PROMPT_EOL_MARK=''
# **Load-bearing, and it does not look it.**  zsh-syntax-highlighting only
# takes effect once a keymap has been selected: with GLOBAL_RCS off and no
# `bindkey` of our own, the plugin loads, reports its version, defines
# `_zsh_highlight` -- and colours nothing.  Measured 2026-09-08 by bisecting
# this file: on Fedora the keymap normally gets selected by /etc/zshrc's
# `bindkey ' ' magic-space`, which GLOBAL_RCS off is exactly what skips.
# `-e` rather than that line, because emacs bindings are what readline gives
# the bash takes and a filmed shell should not do history expansion on space.
bindkey -e
@ALIASES@
# The typist writes bytes one at a time; wrapping them in paste markers would
# put ESC[200~ in the transcript and change nothing on screen.  Same reason the
# bash path turns readline's own bracketed paste off.
unset zle_bracketed_paste
# A right-hand prompt would be redrawn on every keystroke and is nothing but
# noise in a transcript.
unset RPROMPT
HISTFILE=
SAVEHIST=0
setopt NO_BEEP
@HIGHLIGHT@
"""

#: Where the distributions put zsh-syntax-highlighting.  Sourced when it is
#: there and skipped with a verdict when it is not: a take that quietly came
#: out unhighlighted is one nobody notices until the edit.
ZSH_HIGHLIGHT_PATHS = (
    "/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh",
    "/usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh",
    os.path.expanduser("~/.local/share/zsh-syntax-highlighting/"
                       "zsh-syntax-highlighting.zsh"),
)

ZSH_HIGHLIGHT = """
source @PATH@
typeset -gA ZSH_HIGHLIGHT_STYLES
ZSH_HIGHLIGHT_STYLES[command]='fg=green'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=green'
ZSH_HIGHLIGHT_STYLES[function]='fg=green'
ZSH_HIGHLIGHT_STYLES[alias]='fg=green'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=green,underline'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=red'
ZSH_HIGHLIGHT_STYLES[path]='fg=cyan'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=yellow'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=yellow'
ZSH_HIGHLIGHT_STYLES[single-hyphen-option]='fg=blue'
ZSH_HIGHLIGHT_STYLES[double-hyphen-option]='fg=blue'
ZSH_HIGHLIGHT_STYLES[redirection]='fg=magenta'
ZSH_HIGHLIGHT_STYLES[comment]='fg=black,bold'
"""


def zsh_highlighter():
    """The highlighter's path, or None -- reported rather than assumed."""
    for path in ZSH_HIGHLIGHT_PATHS:
        if os.path.isfile(path):
            return path
    return None


#: Flags that belong to the rig rather than to the point being made.  A take
#: that types `ls --color=always -l` is spending a third of its line on
#: something the viewer does not care about, and `bat --theme=ansi` is there
#: for a reason (it stops bat interrogating the terminal -- see shot_looktest)
#: that has nothing to do with what the shot is showing.  Behind an alias they
#: still happen and the line stays about the subject.
#:
#: `--color=auto` rather than `always`: the pty is a tty, so it colours, and a
#: viewer who copies the alias gets something that behaves properly in a pipe.
TAKE_ALIASES = (
    "alias ls='ls --color=auto'",
    "alias grep='grep --color=auto'",
    "alias bat='bat --theme=ansi --style=numbers'",
)

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

    #: The same prompt, inked.  Kept separate from `PS1` because `Board.window`
    #: is ANSI-stripped: what the typist matches is the plain string above, and
    #: what bash draws is this one -- so colour costs the prompt detection
    #: nothing.  `\[`/`\]` mark the escapes zero-width so readline still knows
    #: how long the line is and does not wrap the cursor early.
    #:
    #: Palette INDICES rather than truecolour, deliberately: 4 and 3 are the
    #: accent and accent_alt of whichever project this is filmed for, because
    #: the terminal's sixteen are generated from its `visual_style.json`
    #: (video repo, `utilities/take-backdrop.py`).  The prompt then follows the
    #: project's palette without this file having to know what it is.
    #: The leading newline is air: without it every command, its output and the
    #: next command run together into one wall of text, and on a 4K frame held
    #: for four seconds there is nothing to tell the viewer where one thing
    #: ends and the next begins.  It costs a row per command and buys the only
    #: punctuation a terminal take has.
    PS1_INK = ("\\n\\[\\033[1;34m\\]yasos.zig\\[\\033[0m\\] "
               "\\[\\033[33m\\]$\\[\\033[0m\\] ")

    def __init__(self, rows, cols, cwd=None, ps1=PS1_INK, shell="bash"):
        self.rows, self.cols = rows, cols
        self.closed = False
        self.zdotdir = None
        if shell == "zsh":
            # A throwaway ZDOTDIR, removed with the shell.  `-i` rather than
            # `-f`: `-f` would skip our own rc along with everybody else's, and
            # `unsetopt GLOBAL_RCS` in .zshenv is what keeps /etc out.
            self.zdotdir = tempfile.mkdtemp(prefix="demo-shot-zsh.")
            hl = zsh_highlighter()
            with open(os.path.join(self.zdotdir, ".zshenv"), "w") as fh:
                fh.write("unsetopt GLOBAL_RCS\n")
            with open(os.path.join(self.zdotdir, ".zshrc"), "w") as fh:
                # A plain substitution, not %-formatting: zsh's PROMPT is
                # made of `%B`/`%F{...}` escapes and every one of them would
                # have to be doubled.
                fh.write(ZSHRC
                         .replace("@ALIASES@", "\n".join(TAKE_ALIASES))
                         .replace("@HIGHLIGHT@",
                                  ZSH_HIGHLIGHT.replace("@PATH@", hl) if hl else ""))
            argv = ["zsh", "-i"]
        else:
            argv = ["bash", "--norc", "--noprofile", "-i"]
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
            if self.zdotdir:
                env["ZDOTDIR"] = self.zdotdir
            os.execvpe(argv[0], argv, env)
            os._exit(127)                                   # unreachable
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))
        # Bash 5.1 turns bracketed paste on by default, which wraps everything
        # the typist sends in `ESC[200~`/`ESC[201~`.  Invisible on camera and
        # noise in the transcript -- and the transcript is the artifact a bad
        # take is diagnosed from.  Written rather than typed, and before the
        # screen is cleared, so it is not part of the take.
        if not self.zdotdir:
            os.write(self.fd, b"bind 'set enable-bracketed-paste off' 2>/dev/null\n")
            for line in TAKE_ALIASES:
                os.write(self.fd, line.encode() + b"\n")

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
        if self.zdotdir:
            shutil.rmtree(self.zdotdir, ignore_errors=True)
            self.zdotdir = None
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


# ---------------------------------------------------------------------------
# The floating point beat: apps/fpbench's four arms, run live.
# ---------------------------------------------------------------------------

#: One row per fpbench arm binary and the operation whose "hardware beats
#: software" story is the simplest to read live: a double add is the DCP's
#: shortest sequence, so it is where the four numbers separate the most
#: cleanly on screen.  Matched against fpbench's own `mode=<name> op=<name>
#: ... net_ps=<int>` lines (apps/fpbench/main.c) rather than the `--report`
#: table, so a check can fire right after each arm instead of waiting for the
#: joined table at the end.
_FPBENCH_ARMS = ("soft", "hwlib", "hwstatic", "inline")
_FPBENCH_ROW_RE = re.compile(
    r"^mode=(?P<mode>\w+) op=(?P<op>\w+) ps=(?P<ps>\d+) net_ps=(?P<net>-?\d+)$", re.M)


def fpbench_net_ps(out, mode, op):
    """The net_ps fpbench printed for (mode, op) in *out*, or None."""
    for m in _FPBENCH_ROW_RE.finditer(out):
        if m.group("mode") == mode and m.group("op") == op:
            return int(m.group("net"))
    return None


def shot_fpbench(b, args):
    """Run all four apps/fpbench arms on the board and print the comparison.

    docs/userspace_floating_point.md's three ways to reach a double, as three
    numbers rather than a claim: `dadd` costs about 387 ns as a software call,
    about 28 ns as a call into the DCP-backed runtime, and about 13 ns fully
    inlined -- one C source, four builds differing only in -mfp-inline/-mfp-lib
    (apps/fpbench/Makefile), so the difference on screen is the flags and
    nothing else.

    Each arm is its own program because each links a different __aeabi_
    runtime and those export the same names -- one process holds exactly one.
    `fpbench-inline --report` at the end reads back what the first three wrote
    to /tmp/fpbench.<mode> and joins them into the table the frame closes on.
    """
    iters = f" {args.fpbench_iters}" if args.fpbench_iters else ""
    outputs = {}
    for mode in _FPBENCH_ARMS:
        out = b.command(f"fpbench-{mode}{iters}", timeout=120)
        outputs[mode] = out
        b.check(f"fpbench-{mode} ran", "fpbench: recorded" in out,
                "no \"recorded\" line -- did the binary build for this rootfs?")
        b.beat(0.6)

    soft_dadd = fpbench_net_ps(outputs["soft"], "soft", "dadd")
    inline_dadd = fpbench_net_ps(outputs["inline"], "inline", "dadd")
    if soft_dadd is not None and inline_dadd:
        b.check("inline dadd is cheaper than software dadd",
                inline_dadd < soft_dadd,
                f"soft {soft_dadd} ps, inline {inline_dadd} ps -- no gap to show")
        b.checks.append((f"soft/inline dadd = {soft_dadd / inline_dadd:.1f}x "
                         f"({soft_dadd} ps against {inline_dadd} ps)", True, ""))
    b.beat(1.0)

    report = b.command("fpbench-inline --report", timeout=30)
    b.check("the comparison table printed", "ns per operation" in report,
            "no table header -- did every arm's /tmp/fpbench.<mode> get written?")
    b.beat(3.0)                      # the table is the shot: hold


# ---------------------------------------------------------------------------
# The XIP beat: what one compile costs the bus the board fetches its code over.
# ---------------------------------------------------------------------------

#: Scene 8's claim is that the board does not run from RAM: `tcc` is fetched
#: out of QSPI flash through a 16 KiB cache, over four wires it shares with the
#: PSRAM.  `/proc/xip` is where that stops being an assertion --
#: source/kernel/process/xipstat_file.zig publishes the XIP controller's hit and
#: access counters, drained into 64-bit totals on the 1 kHz tick because the
#: hardware's own are 32-bit and *saturate* rather than wrap.
#:
#: The workload is the one every number on the card is quoted over, timed by
#: the board's own clock (apps/time) so the misses can be turned into a share of
#: the compile instead of left as a count.  `-o /tmp/hello` because /tmp is RAM
#: and the rig board has no SD card: a write that went to one would put the
#: filesystem in the window as well.
XIP_READ = "cat /proc/xip"
XIP_CMD = "time tcc /usr/hello_world.c -o /tmp/hello"

#: One typed line per repeat, with both counter reads *inside it*.
#:
#: Three separate commands would be the obvious shape and would measure the
#: wrong thing: between two reads typed by hand there are several seconds of
#: the shell echoing characters back over the UART, and every tick that fires
#: while it does, all of it landing in a window attributed to the compile.  On
#: one line the only things between the two reads are the compile and the
#: second `cat` -- and the control line prices that `cat`, so it can be taken
#: off.  It is also the better frame: before and after end up on screen
#: together, a dozen lines apart, instead of a screen apart.
XIP_LINE = f"{XIP_READ}; {XIP_CMD}; {XIP_READ}"

#: The empty window: two reads with nothing but the second `cat` between them.
#: What the measurement costs, measured, rather than assumed negligible.
XIP_CONTROL = f"{XIP_READ}; {XIP_READ}"

#: What the card states (ScriptForge motion/s08_b0_xip-and-the-shared-bus.py),
#: so a take that disagrees with it says so in its own verdicts.  It is not a
#: pass/fail: the figures there were measured on 2026-08-03 against a tcc whose
#: `.text` was 2.42 MiB, and the consolidation round took that to 1.41 MiB
#: against a 16 KiB cache -- so a drift here is news about the card, not about
#: the take.
CARD_ACCESSES = 38.30e6
CARD_HIT_RATE = 98.70

#: A miss costs about this many core cycles at 532 MHz -- quoted in passing at
#: crt.zig:516, out of `overclock_flash_probe_read_cost`.  A constant here and
#: not a number the take reads off the board, for a reason worth knowing before
#: reaching for it: the probe that prints "Flash read cost (cycles/access):
#: miss / seq / rnd / loop" at boot is behind `probe_read_cost`, which is a
#: hard-coded `false` at external_memory.zig:363 -- so the banner on this
#: board says "Flash continuous-read enabled" with no numbers after it, and
#: sourcing the cost live would cost a kernel rebuild and a reflash.
#:
#: The clock is likewise the board's by configuration, from
#: configs/pimoroni_pico_plus2_and_vga_defconfig:41 (and confirmed on the boot
#: banner, "FREQ: 532 MHz"); nothing in /proc reports it, so a take on another
#: config has to be told.
XIP_MISS_CYCLES = 146.0
XIP_CORE_HZ = 532e6

# xipstat_file.zig prints exactly `xip_hit`, `xip_acc`, `xip_saturated`, in that
# order, one per line.  Matched the same way tests/smoke/measure_test.py does.
_XIP_RE = re.compile(r"^xip_(hit|acc|saturated)\s+(\d+)\s*$", re.M)


def xip_reads(out):
    """Every complete `cat /proc/xip` in *out*, in order.

    A list rather than one dict because the shot's whole shape is two reads in
    one command: a key arriving that the current read already holds is where
    the next one starts.
    """
    reads, current = [], {}
    for key, value in _XIP_RE.findall(out):
        if key in current:
            reads.append(current)
            current = {}
        current[key] = int(value)
    if current:
        reads.append(current)
    want = {"hit", "acc", "saturated"}
    return [read for read in reads if want <= read.keys()]


def xip_delta(out, label, b):
    """The window between the first and last read in *out*, or None.

    Returns `(acc, miss, saturated)`.  Records the verdict itself, because
    every caller fails the same way for the same reason and a shot that has
    lost the counters has nothing left to measure.
    """
    reads = xip_reads(out)
    if len(reads) < 2:
        b.check(f"{label} bracketed the window", False,
                f"{len(reads)} of 2 reads of /proc/xip parsed -- is this an "
                "RP2350 kernel with the XIP sampler wired up?")
        return None
    first, last = reads[0], reads[-1]
    acc = last["acc"] - first["acc"]
    hit = last["hit"] - first["hit"]
    return acc, acc - hit, last["saturated"] - first["saturated"]


def shot_xip(b, args):
    """Count what one compile costs the shared QSPI bus, on the board.

    Scene 8 tells the viewer two numbers that pull against each other -- there
    is a cache, so it is not every instruction; and a miss costs ~146 core
    cycles -- and the frame answers which one wins with a hit rate and a miss
    count.  This is where those come from: `/proc/xip`, read on the board,
    either side of a `tcc /usr/hello_world.c` compile, five times.

    What makes it a measurement rather than two numbers on a screen:

    * **The reads are inside the compile's own command line.**  See `XIP_LINE`.
    * **There is a control window.**  `XIP_CONTROL` is the same pair of reads
      with nothing between them but the second `cat`, so the bracketing's own
      traffic is a number rather than an assumption.
    * **Saturation fails the take.**  The hardware counters stick at their
      maximum instead of wrapping, and `xip_saturated` counts the tick samples
      that arrived pinned.  A window with any is a floor, not a count, and the
      shot refuses to report it as one.
    * **Five repeats, and the spread is checked.**  One compile is an anecdote;
      five that agree to a tenth of a percent are the thing the card claims.

    The stall estimate in the verdicts is an **upper bound**, and deliberately
    not the card's 65%.  It is the naive product -- misses x ~146 cycles /
    532 MHz -- which prices every miss at the *random* access cost, while a
    burst of sequential misses is cheaper (the boot probe reports miss, seq,
    rnd and loop separately).  The card's 35/65 split comes from fitting wall
    time across the clock A/B, which is a different and gentler model; the two
    disagreeing is expected and both are on the frame as what they are.
    """
    repeats = max(1, args.xip_repeats)

    # The file itself first, on its own, with nothing derived: three fields,
    # totals since boot.  The beat is the viewer reading them.
    b.command(XIP_READ)
    b.beat(3.0)

    control = xip_delta(b.command(XIP_CONTROL), "the control window", b)
    if control is None:
        return
    b.beat(2.0)

    samples = []
    for k in range(repeats):
        out = b.command(XIP_LINE, timeout=300)
        wall = timing_in(out)
        b.check(f"compile #{k + 1} printed a time", wall is not None,
                "no `real` line -- is `time` in this rootfs?")
        # tcc is silent on success, so anything at all here is the error path,
        # and a row measuring the error path is worse than no row.
        b.check(f"compile #{k + 1} compiled cleanly",
                "error" not in out.lower() and "not found" not in out.lower(),
                "tcc printed a diagnostic -- the window is not a compile")
        window = xip_delta(out, f"compile #{k + 1}", b)
        if window is None:
            return
        samples.append((window, wall))
        b.beat(2.0)

    b.beat(3.0)                  # the last pair of reads is the shot: hold

    # --- what the take measured, after it has ended -------------------------
    acc_control, miss_control, sat_control = control
    hit_rate_control = 100.0 * (acc_control - miss_control) / acc_control if acc_control else 0.0
    b.checks.append((
        f"control window (two reads, one `cat` between): acc={acc_control:,} "
        f"miss={miss_control:,} hit={hit_rate_control:.2f}%", True, ""))

    saturated = sat_control + sum(w[2] for w, _ in samples)
    b.check("the counters never saturated", saturated == 0,
            f"{saturated} pinned sample(s) -- every figure here is a floor, "
            "not a count.  RETAKE")

    rates = []
    for k, ((acc, miss, _sat), wall) in enumerate(samples):
        net_acc = acc - acc_control
        net_miss = miss - miss_control
        rate = 100.0 * (net_acc - net_miss) / net_acc if net_acc else 0.0
        rates.append(rate)
        stall = net_miss * XIP_MISS_CYCLES / XIP_CORE_HZ
        share = f"{100.0 * stall / wall:5.1f}%" if wall else "    ? "
        shown = f"{wall:.3f}s" if wall else "     ?"
        b.checks.append((
            f"compile #{k + 1}: wall={shown}  "
            f"acc={net_acc:>12,}  miss={net_miss:>10,}  hit={rate:6.2f}%  "
            f"stall<={stall * 1000:6.1f}ms ({share} of wall, upper bound)",
            True, ""))
        b.check(f"compile #{k + 1} moved the counters", net_acc > 1_000_000,
                f"{net_acc:,} accesses -- did the compile actually run?")

    if not rates:
        return

    spread = max(rates) - min(rates)
    b.check("the hit rate held across the repeats", spread < 1.0,
            f"{spread:.2f} points between {min(rates):.2f}% and "
            f"{max(rates):.2f}% -- these are not five runs of one thing")

    walls = sorted(w for _, w in samples if w)
    median_wall = walls[len(walls) // 2] if walls else None
    median_rate = sorted(rates)[len(rates) // 2]
    median_acc = sorted((a - acc_control) for (a, _m, _s), _w in samples)[len(samples) // 2]
    b.checks.append((
        f"median of {len(samples)}: "
        + (f"wall={median_wall:.3f}s  " if median_wall else "")
        + f"acc={median_acc / 1e6:.2f} M  hit={median_rate:.2f}%  "
        f"one miss every {1.0 / (1.0 - median_rate / 100.0):.0f} accesses",
        True, ""))

    # Not a check: see CARD_ACCESSES.  A disagreement here is a note to the
    # card, and the take is still good.
    b.checks.append((
        f"card says acc={CARD_ACCESSES / 1e6:.2f} M hit={CARD_HIT_RATE:.2f}%; "
        f"this take says acc={median_acc / 1e6:.2f} M hit={median_rate:.2f}% "
        f"({median_rate - CARD_HIT_RATE:+.2f} points, "
        f"{100.0 * (median_acc / CARD_ACCESSES - 1.0):+.1f}% accesses)"
        + ("" if abs(median_rate - CARD_HIT_RATE) < 0.25
           else "  <-- UPDATE s08_b0"),
        True, ""))


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


# ---------------------------------------------------------------------------
# The torture-suite beat: real GCC tests, compiled and run by hand on the board.
# ---------------------------------------------------------------------------

#: Where the corpus already lives on the target.  The smoke harness uploads
#: each test over zmodem once and caches it under `/root/ci/sources/v2`
#: (tests/smoke/tcc_suite_test.py, the batched-upload path), so the tests on
#: screen are the ones CI runs -- not a folder assembled for the camera.  The
#: rig board has no SD card; this is flash-backed rootfs, which is also why the
#: take never writes anything but /tmp.
TESTS_ROOT = "/root/ci/sources/v2"
TESTS_DIR = TESTS_ROOT + "/gcc_torture/execute"

#: Which shard to run.  The corpus is sharded into hex directories, and this one
#: is 48 tests that all pass -- verified on hardware 2026-09-04, 48/48 in 6.8 s.
#: Picking a shard rather than a hand-written list matters on camera: a list
#: reads as cherry-picking, a directory does not.  Two neighbours are *not*
#: clean and the reason is worth knowing before switching shards: `00` fails
#: `pr28982b.c` and `01` fails `pr20621-1.c`, both because the test asks for a
#: stack this board does not hand out by default -- pr28982b carries
#: `dg-require-stack-size "0x80100"` and puts a 256 KiB struct on the stack.
#: The real harness reads that directive and grants it; a shell loop cannot, so
#: those two would fail on camera for a reason that has nothing to do with
#: codegen.
TESTS_SHARD = "03"

#: The one test that gets read out on screen.  Twenty lines, a struct returned
#: by value, a 64-bit multiply and `__builtin_abort()` -- it fits a frame, it is
#: obviously not a hello-world, and it exercises exactly the parts of the
#: backend this part of the video is about.
TESTS_CAT = "pr93402.c"

#: One line, and it has to stay one line: `cd` first so the loop prints bare
#: test names instead of 48 copies of the path, and `&&`/`||` rather than an
#: `if` so the shape of the thing being typed is readable while it is typed.
#: Note there is no `2>/dev/null` anywhere in this take -- /dev/null on this
#: board is on a read-only filesystem and the redirect fails the command.
TESTS_LOOP = ('for f in *.c; do tcc -O2 $f -o /tmp/t && /tmp/t '
              '&& echo "PASS $f" || echo "FAIL $f"; done')

_TESTS_PASS_RE = re.compile(r"^PASS (\S+\.c)$", re.M)
_TESTS_FAIL_RE = re.compile(r"^FAIL (\S+\.c)$", re.M)


def shot_tests(b, args):
    """Compile and run real GCC torture tests, by hand, on the board.

    Part one's claim is that the compiler is *correct*, and this is that claim
    with nobody's harness in the way: the tests are the ones CI uploaded, the
    compiler is the board's own tcc, and the loop is four commands typed at the
    board's shell.  Nothing here is a report about a run that happened
    somewhere else.

    **No clock, and it is a shot rule.**  Part one shows no elapsed timer
    anywhere (`recording-plan.md`, "The clock rule"), so this take never runs
    `time` and never asks the board how long anything took.  What it shows is
    PASS lines arriving faster than they can be read, which is the same fact
    without answering the question part two opens on.

    The exit code is the test protocol, not a flourish: a gcc.c-torture execute
    test calls `abort()` when it disagrees with its own expected value and
    returns 0 otherwise, so `echo rc=$?` after the first one is the whole
    contract on screen before the loop leans on it 48 times.
    """
    shard = args.tests_shard
    d = f"{TESTS_DIR}/{shard}"

    # The corpus, where it lives.  Two `ls` rather than one: the first says the
    # board holds whole suites -- gcc_torture, gcc.dg, gcc.target, tinycc's own
    # ir_tests and tests2 -- and the second says what a shard of one looks like.
    b.command(f"ls {TESTS_ROOT}")
    b.beat(1.2)
    listing = b.command(f"ls {d}")
    b.check("the board holds the torture corpus", ".c" in listing,
            f"nothing that looks like a test under {d}")
    b.beat(2.5)                      # the viewer reads the names

    b.command(f"cd {d}")
    out = b.command(f"cat {args.tests_cat}")
    b.check("the test is on screen", "abort" in out,
            f"{args.tests_cat} does not look like an execute test")
    b.beat(3.5)                      # the viewer reads the program

    b.command(f"tcc -O2 {args.tests_cat} -o /tmp/t", timeout=180)
    b.beat(1.0)
    ran = b.command("/tmp/t; echo rc=$?", timeout=120)
    b.check("the test passed on the board", "rc=0" in ran,
            "the binary the board built did not return 0")
    b.beat(2.0)

    # Then the whole shard, one line, no harness.
    out = b.command(TESTS_LOOP, timeout=600)
    passed = _TESTS_PASS_RE.findall(out)
    failed = _TESTS_FAIL_RE.findall(out)
    files = [n for n in listing.split() if n.endswith(".c")]
    b.check(f"every test in {shard} passed", passed and not failed,
            f"{len(failed)} failed: {', '.join(failed[:6])}")
    b.check("the loop ran every test in the directory",
            len(passed) + len(failed) == len(files),
            f"{len(passed) + len(failed)} results for {len(files)} files -- "
            "did the listing scroll?")
    b.checks.append((f"{len(passed)}/{len(files)} tests compiled and run "
                     f"on the board, shard {shard}", True, ""))
    b.beat(4.0)                      # the payoff is the last screen: hold it


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


#: Cleared before the build, because `build_rootfs.sh` stamps each stage and
#: skips it when nothing under libs/tinycc is newer -- right for working and
#: useless for filming, where the take would be four lines of "already up to
#: date".  Only the NATIVE stages are cleared: the cross compiler stays as it
#: is, so the take shows it doing the work rather than being rebuilt itself.
#: One line from the repo root -- the old take spent a `cd` and a `cd ../..` on
#: this and they were the first thing on camera, which is a poor first frame
#: for the video.
CROSSTCC_STAMPS = ("rm -f libs/tinycc/.yasos-build/native-stage1.stamp"
                   " libs/tinycc/.yasos-build/native-stage2.stamp")

#: What went in.  `git ls-files` rather than `find`, so the count is the
#: tracked sources and nobody can ask whether it swept a build directory;
#: `tests/` and `lib/` are excluded because they are the test corpus and the
#: shipped runtime, not the compiler.  Both run from the repo root -- `git -C`
#: for the count, a subshell for the lines, because `ls-files` prints paths
#: relative to libs/tinycc, so xargs puts the prefix back before `cat` opens
#: them.  A subshell would be shorter and was what this did first; `git -C` on
#: both lines makes the pair read as a pair on the one screen that holds them,
#: and it survives a shell where `( )` means something else.
#: Keeping the prompt at the root is what lets the two numbers and the two
#: sizes share one screen, which is the screen the voiceover is describing.
_SOURCES = "ls-files -- '*.c' '*.h' ':!tests/*' ':!lib/*'"
CROSSTCC_FILES = f"git -C libs/tinycc {_SOURCES} | wc -l"
CROSSTCC_LINES = (f"git -C libs/tinycc {_SOURCES}"
                  " | xargs -I{} cat libs/tinycc/{}"
                  " | grep -cve '^[[:space:]]*$'")


def shot_crosstcc(b, args):
    """tcc compiling tcc, what went in and what came out, then the board using it.

    The script's opening shot, and it is the opening *sentence* in the order
    the sentence says it: a C compiler compiling a C compiler, then a quarter
    of a million lines of C in and about one and a half megabytes of ARM out,
    and then that binary on the microcontroller compiling and running a test.
    Re-shot 2026-09-08; the 2026-09-04 take counted first and never left this
    desk.

    **The build is a HOST build and the take must not pretend otherwise**
    (`changes.md` G6): `build_rootfs.sh` runs here, on the desktop, and the
    compiler doing the work is `armv8m-tcc` -- tcc built for this machine,
    emitting ARM.  The board does not rebuild TinyCC and cannot: no make on
    target, and the sources do not fit in the RAM it has.  What the board does
    is the last leg of this take, and it is compiling a *test*, not itself.

    What makes the build worth filming rather than drawing is that the compiler
    names itself twice, unprompted: configure prints `C compiler armv8m-tcc`,
    and every recipe line that scrolls past is `armv8m-tcc -o armv8m-source/...
    -c source/...`.  Both are checked, because a take where gcc quietly did the
    work would look exactly the same at this speed.

    The board leg goes through `remote_smoke_tui.py --connect`, which is the
    honest way in: no build, no flash, no reset -- it attaches to the UART of
    whatever is already on the board, so what compiles the test is the binary
    this take just weighed rather than one uploaded for the occasion.  It is
    also why this shot now takes the rig busy-check: the old one skipped it on
    the grounds that it was a build on this desk, and that stopped being true
    the moment the take reached for the board.

    No clock: part one shows no elapsed timer, and neither the build nor the
    test is timed on camera even though the build takes about twenty seconds.
    """
    # -- the compiler compiling the compiler ---------------------------------
    b.beat(0.8)
    b.command(CROSSTCC_STAMPS)
    b.beat(0.6)
    # The stamps are housekeeping -- true, necessary, and not the sentence.
    # Cleared off before the build so the video's FIRST frame is the compiler
    # being asked to build itself, with nothing above it.
    b.command("clear")
    b.beat(0.8)
    out = b.command("./build_rootfs.sh", timeout=args.rig_timeout)
    b.check("the cross compiler was not the thing being rebuilt",
            "Cross compiler already up to date." in out,
            "the cross stage ran too -- that is a different shot")
    b.check("the native compiler was built", "Building C compiler..." in out,
            "the native stage did not run -- were the stamps cleared?")
    b.check("configure named tcc as the C compiler",
            re.search(r"C compiler\s+armv8m-tcc", out) is not None,
            "no `C compiler armv8m-tcc` line -- did something fall back to gcc?")
    b.check("tcc compiled tcc's own sources",
            "armv8m-tcc -o armv8m-source/" in out,
            "no recipe line shows armv8m-tcc compiling source/ -- "
            "the scroll is not what this shot claims it is")
    b.beat(1.5)

    # -- what went in, and what came out, on one screen -----------------------
    # `clear` earns its keystroke: build_rootfs.sh goes on past the compiler to
    # build the rest of the userland, so the last screen before this is
    # toybox's warnings and a `strip failed` line -- true, and nothing to do
    # with the beat.  The four numbers the voiceover says get a screen to
    # themselves.
    b.command("clear")
    b.beat(0.8)
    # One count, not two.  The file count came off on 2026-09-08: 622 is a
    # number the voiceover never says, and on a screen whose job is to hold
    # the four figures the sentence is about, a fifth is subtraction.  The
    # pathspec still excludes `tests/` and `lib/` for the same reason it
    # always did -- they are the corpus and the shipped runtime, not the
    # compiler -- and the count is still of tracked sources, so nobody can
    # ask whether it swept a build directory.
    lines = b.command(CROSSTCC_LINES, timeout=120)
    counted = [int(n) for n in re.findall(r"^\s*(\d+)\s*$", lines, re.M)]
    b.check("a quarter of a million lines of C go in",
            counted and max(counted) > 200_000,
            f"counted {counted or 'nothing'} -- the corpus should be ~235,000")
    if counted:
        b.checks.append((f"{max(counted):,} non-blank lines of C in", True, ""))
    b.beat(2.0)

    size = b.command("arm-none-eabi-size libs/tinycc/bin/armv8m-tcc.elf",
                     timeout=60)
    text = re.search(r"^\s*(\d+)\s+\d+\s+\d+\s", size, re.M)
    b.check("the ARM binary was weighed", text is not None,
            "no size line -- is arm-none-eabi-size installed?")
    if text:
        b.checks.append((f"{int(text.group(1)):,} B of ARM .text out "
                         f"({int(text.group(1)) / 1024:.1f} KiB)", True, ""))
    b.beat(2.0)
    shipped = b.command("ls -l rootfs/usr/bin/tcc", timeout=60)
    b.check("the compiler that ships was produced", "tcc" in shipped,
            "rootfs/usr/bin/tcc is not there")
    b.beat(3.0)

    # -- and that binary, on the board, compiling a test ---------------------
    b.command("clear")
    b.beat(0.6)
    b.type("./scripts/remote_smoke_tui.py --connect")
    b.beat(0.6)
    b.press(b"\n")
    b.check("the console came up",
            b.expect("Exit with Ctrl-]", timeout=120),
            "--connect never announced the port -- is the Pi reachable?")

    # The board's prompt is `$ `, not this desk's.  `Board.at` is exactly this:
    # one take, two prompts.  A bare Enter first because miniterm attaches to a
    # board that has been sitting at an idle prompt with nothing to redraw it,
    # so without this the take waits out its timeout in front of a blank line.
    with b.at(PROMPT):
        b.press(b"\n")
        b.check("the board answered", b.wait_prompt(30.0),
                "no prompt on the console -- is the board powered and booted?")
        b.beat(1.2)

        # **This desk's prompt ends in `$ ` too, and that is not a detail.**
        # Measured 2026-09-08: the serial console died on connect (the board
        # was unplugged), miniterm raised, ssh closed, and control came back to
        # the local zsh -- whose prompt `wait_prompt` then matched happily. The
        # take typed the next three commands AT THIS DESKTOP: `cat pr93402.c`,
        # `tcc -O2 ...`, `/tmp/t; echo rc=$?`, collecting "No such file",
        # "command not found" and rc=127, and every check still passed the way
        # a take that never reached the board would.
        #
        # So the `cd` is the gate.  It has to happen anyway, it is the first
        # thing that can only succeed on the board, and its failure is the
        # cheapest possible evidence that the console is not what it claims.
        # Nothing after it is typed unless it lands.
        # `--connect` arrives after a page of the rig's own shell environment
        # -- `run_remote_tty_script` runs the console under `bash -lc` and
        # something on the way prints a full `set`.  Not this take's business
        # to fix, and not something to leave in frame either: the board's own
        # `clear` (toybox, it is in rootfs/usr/bin) wipes it, and the shot
        # opens on a clean console instead of on somebody's XDG variables.
        b.command("clear", timeout=30)
        b.beat(0.8)

        d = f"{TESTS_DIR}/{args.tests_shard}"
        moved = b.command(f"cd {d}", timeout=60)
        on_board = not re.search(r"[Nn]o such file|not found", moved)
        b.check("the console is the board, not this desk", on_board,
                f"`cd {d}` failed -- the console dropped and this shell is the "
                "desktop's. Nothing after this was typed.")

        if on_board:
            # `ccat`, not `cat`: a wall of white text is a poor way to show
            # somebody a program, and the board has no `bat` to reach for --
            # that is Rust on libgit2 and libonig, and this is a Cortex-M33
            # with a C compiler.  So `apps/ccat` is the same idea at a size
            # the board can hold, and `armv8m-tcc` built it, which makes the
            # listing one more thing the compiler this video is about produced.
            out = b.command(f"ccat -n {args.tests_cat}", timeout=60)
            b.check("the test is on screen", "abort" in out,
                    f"{args.tests_cat} does not look like an execute test")
            # Not a check for the escapes: `command()` hands back
            # `Board.window`, which is ANSI-stripped, so colour is invisible
            # from in here by construction.  What can be checked is that the
            # board HAD the program -- a rootfs flashed before apps/ccat
            # existed answers "not found" and the listing is simply missing.
            b.check("the board has ccat", "not found" not in out,
                    "ccat is not on this rootfs -- flash one built since "
                    "apps/ccat landed, or fall back to `cat`")
            b.beat(4.0)              # the viewer reads the program

            b.command(f"tcc -O2 {args.tests_cat} -o /tmp/t", timeout=180)
            b.beat(1.2)
            # The exit code is the test protocol, not a flourish: a
            # gcc.c-torture execute test calls `abort()` when it disagrees with
            # its own expected value and returns 0 otherwise, so `rc=0` is the
            # whole contract.
            ran = b.command("/tmp/t; echo rc=$?", timeout=120)
            b.check("the test passed on the board", "rc=0" in ran,
                    "the binary the board built did not return 0")
            b.beat(3.5)              # the payoff of the take: hold it

    b.press(b"\x1d")                 # Ctrl-]: miniterm lets go
    b.check("back at this desk", b.wait_prompt(30.0),
            "the console did not exit -- Ctrl-] went nowhere")
    b.beat(2.0)


def shot_looktest(b, args):
    """The terminal's own look, filmed: palette, prompt, highlighting, spacing.

    A companion to `rig_dry`, and it exists for the same reason.  The look of a
    take -- the sixteen colours, the backdrop, the shell's highlighting, the
    mark on a number -- is decided by four files in two repositories, and the
    only way to know what it comes out like is to point a camera at it.  Before
    this, every look change was judged from a still grabbed off a throwaway
    recording; this makes it a take, with a transcript, that lands beside the
    others.

    Touches nothing: no board, no rig, no build.  Every command reads.

    Nothing here is piped through anything of ours.  Emphasis on a number is
    the cut's job now, not the shell's.
    """
    b.beat(0.8)

    # Colour that is not ours: git and ls choose their own SGR codes, and the
    # point is that they land in this project's hues because the terminal's
    # sixteen are what resolve them.
    b.command("git -c color.ui=always log --oneline -3")
    b.beat(1.6)
    listing = b.command("ls -l rootfs/usr/bin/ | head -6")
    b.check("the listing came back", "toybox" in listing or "tcc" in listing,
            "nothing under rootfs/usr/bin -- has the rootfs been built?")
    b.beat(2.0)

    # What went in, counted without a subshell -- the form that survives a
    # shell whose `()` means something else.  `libs/tinycc` is a submodule, so
    # `git -C` and a path put back on with xargs is what reaches the files.
    files = b.command(CROSSTCC_FILES, timeout=60)
    b.check("the source count came back",
            re.search(r"^\s*(\d+)\s*$", files, re.M) is not None,
            "no count printed -- is this a git checkout?")
    b.beat(2.0)

    # The number the voiceover is about, printed plainly.  It used to be piped
    # through `spotlight` so the field arrived already marked; that came off on
    # 2026-09-08 -- a pipe into a tool from the video repo is a line no viewer
    # can retype, and it put the mechanics of the edit on camera.  The emphasis
    # belongs in the cut, over footage that stays honest.
    b.command("arm-none-eabi-size libs/tinycc/bin/armv8m-tcc.elf", timeout=60)
    b.beat(3.0)

    # `--theme=ansi` is doing two jobs.  Without it `bat` asks the terminal
    # what colour its background is (OSC 10/11) to choose a light or dark
    # theme -- and `Board` is the terminal for this pty, answers CPR and
    # nothing else, so the query travels on to kitty, kitty answers into the
    # take's own input, and `rgb:e9e9/ebeb/eeee` is printed on camera as text.
    # Measured 2026-09-08 by filming it.  Pinning the theme skips the question,
    # and `ansi` is the right answer anyway: it makes bat paint with the
    # terminal's sixteen, which are this project's palette, rather than with
    # its own pinks and oranges.
    b.command("bat --line-range 1:8 build_rootfs.sh", timeout=60)
    b.beat(3.5)                      # hold the last screen: it is the shot


def shot_rig_full(b, args):
    """Flash, then debug -- the whole rig arc in one take."""
    shot_rig_flash(b, args)
    b.beat(2.0)
    shot_rig_gdb(b, args)


RIG_SHOTS = {
    "crosstcc": shot_crosstcc,
    "looktest": shot_looktest,
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
    "fpbench": shot_fpbench,
    "xip": shot_xip,
    "tests": shot_tests,
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
    p.add_argument("--xip-repeats", type=int, default=5,
                   help="compiles the xip shot brackets (default 5, which is "
                        "the `median of five` the card is quoted over)")
    p.add_argument("--tests-shard", default=TESTS_SHARD,
                   help="which gcc_torture/execute shard the `tests` shot runs "
                        "(default: %(default)s, 48 tests, all passing)")
    p.add_argument("--tests-cat", default=TESTS_CAT,
                   help="the test the `tests` shot reads out on screen "
                        "(default: %(default)s)")
    p.add_argument("--fpbench-iters", type=int, default=None,
                   help="iterations per trial for the fpbench shot (default: "
                        "apps/fpbench's own DEFAULT_ITERS, 20000)")
    p.add_argument("--size", metavar="ROWSxCOLS",
                   help="size to report to vi (default: this terminal's)")
    p.add_argument("--transcript", metavar="PATH",
                   help="write everything the board sent, for --extract")
    p.add_argument("--report", metavar="PATH", help="write the verdicts here too")
    p.add_argument("--keylog", metavar="PATH",
                   help="log when each key was struck, for the click track "
                        "the recorder synthesises afterwards "
                        "(utilities/keyclack.py in the video repo)")
    p.add_argument("--quiet", action="store_true",
                   help="keep the verdicts out of the shot: --report only, "
                        "nothing to stderr")
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
    p.add_argument("--shell", choices=("bash", "zsh"), default="bash",
                   help="the shell a rig take types into. zsh brings "
                        "zsh-syntax-highlighting with it -- commands, paths, "
                        "quoted strings and options coloured as they are typed, "
                        "in the project's own palette. Measured 2026-09-08 "
                        "against the typist: the prompt is not re-emitted after "
                        "Enter, so `command()` does not race the way it would "
                        "under fish (default: %(default)s)")
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
        if args.shot not in ("rig_dry", "looktest") and not args.no_lock:
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
        ser = Shell(rows, cols, cwd=args.cwd, shell=args.shell)
        prompt = Shell.PS1
        if args.shell == "zsh" and zsh_highlighter() is None:
            print("zsh-syntax-highlighting not found -- the take will be "
                  "unhighlighted; install it or pass --shell bash", file=sys.stderr)
    else:
        import serial   # only the board path needs it; --extract runs anywhere
        ser = serial.Serial(args.port, args.baud, timeout=0.02)
        prompt = PROMPT
    board = Board(ser, sys.stdout.buffer, rows, cols, args.cps, transcript,
                  prompt=prompt, keylog=args.keylog)

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
            # ...and then ask the board for a fresh prompt.  The clear wipes
            # the one it had already drawn, so without this the take opens on a
            # command typed at column zero with nothing in front of it -- which
            # is exactly what the first recorded `xip` take looked like, and
            # the same fault the rig path fixed with Ctrl-L.  Ctrl-L is the
            # tidier ask and is not available here: that is bash redrawing its
            # own line, and nothing on this side knows what the target's shell
            # does with 0x0c.  An Enter costs one blank row at the top of the
            # frame, which on a terminal is nothing anybody can see.
            board.press(b"\n")
            board.wait_prompt(timeout=5)

    try:
        {**SHOTS, **RIG_SHOTS}[args.shot](board, args)
    except KeyboardInterrupt:
        board.check("take completed", False, "interrupted")
    finally:
        board.pump(0.3)
        ser.close()
        board.keylog_close()
        if transcript:
            transcript.close()

    failed = [c for c in board.checks if not c[1]]
    lines = [f"{'ok  ' if ok else 'FAIL'} {name}" + (f" -- {detail}" if detail and not ok else "")
             for name, ok, detail in board.checks]
    lines.append(f"{len(board.checks) - len(failed)}/{len(board.checks)} checks passed"
                 + ("" if not failed else "  <-- RETAKE"))
    report = "\n".join(lines)
    # A recorded take ends on its payoff -- the last thing the board printed,
    # sitting still, which is where an editor cuts.  Twenty-five verdict lines
    # printed into the same terminal scroll that off the screen in the last
    # second and a half of the clip, and the wrapper's `-t` puts them there
    # whatever `2>` says, because a pty has one stream.  So `--quiet` sends
    # them to the file instead -- but only when there IS a file: verdicts that
    # go nowhere are worse than verdicts in the shot.
    if not args.quiet or not args.report:
        print("\n" + report, file=sys.stderr)
    if args.report:
        open(args.report, "w").write(report + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
