"""
 Copyright (c) 2025 Mateusz Stadnik

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

# Smoke test for the bundled vi (apps/yasvi -> /usr/bin/vi), an ncurses
# full-screen editor. It runs in raw + nodelay mode: getch() is non-blocking
# inside a busy redraw loop, repainting the whole screen on every keystroke.
#
# We deliberately do NOT parse vi's screen (it is a stream of cursor-movement
# and colour escape sequences with a line-number gutter). Instead we drive vi
# "blind" -- send keystrokes, save, quit -- and verify the *file* afterwards
# with cat, which is line-oriented and deterministic. This exercises the real
# editing path (insert mode, line breaks, normal-mode navigation, :w/:wq) end
# to end, on hardware/QEMU, while keeping the assertions robust.

import re
import time

from .conftest import session_key

ESC = "\x1b"
# vi's command line (":...") and insert-mode line breaks both commit on '\n'
# (see apps/yasvi/editor.c: editor_collect_command / editor_insert_char).
ENTER = "\n"

VI_PATH = "/tmp/vi_smoke.txt"


def _vi_feed(session, keys, settle=0.3):
    """Send raw keystrokes to a running vi, then let it settle and drain.

    vi repaints the whole screen on every key; pace input so a slow repaint
    can't drop bytes (UART RX overrun on real hardware) and drain vi's output
    so neither side's serial buffer bloats. The drained bytes are still logged
    by _drain_serial_buffer for post-mortem.
    """
    session.serial.write(keys.encode("utf-8"))
    session.serial.flush()
    time.sleep(settle)
    session._drain_serial_buffer()


def _vi_open(session, path):
    """Launch vi on *path* and wait for it to take over the terminal.

    write_command confirms the shell echoed the launch line; after that vi has
    grabbed the terminal and the prompt will not return until we :wq / :q.
    """
    session.write_command(f"vi {path}")
    time.sleep(1.5)  # initscr() + the first full-screen paint
    session._drain_serial_buffer()


def _vi_save_quit(session):
    """':wq' + Enter -> vi writes the buffer, endwin()s, shell prompt returns.

    Read straight through to the prompt rather than draining: vi's exit emits
    the command-line repaint plus the endwin() clear/reset sequence and *then*
    the shell reprints '$ '. Draining here would swallow that prompt and the
    later wait would hang.
    """
    session.serial.write((":wq" + ENTER).encode("utf-8"))
    session.serial.flush()
    return session.wait_for_prompt_except_logs(timeout=10)


def _cat_lines(session, path):
    session.write_command(f"cat {path}")
    return session.wait_for_prompt_except_logs(timeout=10)


def _read_file_bytes(session, path):
    """Return the on-disk bytes of *path* via hexdump.

    cat-then-wait_for_prompt_except_logs can't be used to detect a stray blank
    line: that helper strips empty lines, so 'AAA\\n\\nBBB' and 'AAA\\nBBB' look
    identical. hexdump exposes the exact bytes. The bundled hexdump prints
    classic od-style output: an octal offset followed by little-endian 16-bit
    words, e.g.  '0000000 4141 0a41 4242 0a42'  ->  41 41 41 0a 42 42 42 0a.
    """
    session.write_command(f"hexdump {path}")
    lines = session.wait_for_prompt_except_logs(timeout=10)
    out = bytearray()
    for line in lines:
        toks = line.split()
        if not toks or len(toks[0]) != 7:  # need the 7-digit offset prefix
            continue
        for tok in toks[1:]:
            if len(tok) != 4:
                continue
            word = int(tok, 16)
            out.append(word & 0xFF)        # low byte first (little-endian)
            out.append((word >> 8) & 0xFF)
    return bytes(out)


def test_vi_enter_single_line_break(request):
    """One Enter == one line break, whatever the terminal sends.

    Regression guard for the CRLF bug: yasos_curses left the tty non-raw, so the
    kernel mapped CR->NL and a CRLF-sending terminal produced two newlines (an
    extra blank line) per Enter. Drive vi with a raw CR, LF and CRLF and assert
    the saved file is byte-for-byte 'AAA\\nBBB\\n' in every case.
    """
    session = request.node.stash[session_key]
    for tag, path, nl in [("CR", "/tmp/vi_cr.txt", "\r"),
                          ("LF", "/tmp/vi_lf.txt", "\n"),
                          ("CRLF", "/tmp/vi_crlf.txt", "\r\n")]:
        session.write_command(f"rm -f {path}")
        session.wait_for_prompt_except_logs()

        _vi_open(session, path)
        _vi_feed(session, "i")
        _vi_feed(session, "AAA")
        _vi_feed(session, nl)              # the Enter under test
        _vi_feed(session, "BBB")
        _vi_feed(session, ESC)
        _vi_save_quit(session)

        assert _read_file_bytes(session, path) == b"AAA\nBBB\n", tag

        session.write_command(f"rm -f {path}")
        session.wait_for_prompt_except_logs()


def test_vi_detects_terminal_size_via_cpr(request):
    """vi adopts the terminal's real size instead of a hardcoded 24x80.

    A serial line carries no size and the kernel's TIOCGWINSZ is hardcoded, so
    initscr() probes the terminal with the Cursor Position Report handshake
    (writes ESC[999;999H ESC[6n and parses the ESC[<rows>;<cols>R reply). A
    too-small terminal otherwise made vi scroll/garble (cursor jumping rows,
    duplicated bottom line, line 1 unreachable). Emulate a 15x50 terminal by
    answering the probe and confirm vi lays out for 15 rows, not the 24x80
    fallback: the status bar's per-key indicator sits at height-1 / width-30, so
    a 15-row screen confines all cursor moves to row <=15 (ANSI), vs ~24 at 24x80.
    """
    session = request.node.stash[session_key]
    session.write_command("rm -f /tmp/vi_cpr.txt")
    session.wait_for_prompt_except_logs()

    session.serial.write(b"vi /tmp/vi_cpr.txt\n")
    session.serial.flush()
    session.serial.timeout = 0.1
    buf = bytearray()
    answered = False
    deadline = time.time() + 4.0
    while time.time() < deadline:
        try:
            chunk = session.serial.read(128)
        except OSError:
            break
        if chunk:
            buf += chunk
            if not answered and b"\x1b[6n" in buf:
                session.serial.write(b"\x1b[15;50R")  # rows=15, cols=50
                session.serial.flush()
                answered = True
                deadline = time.time() + 1.5  # let it repaint at the new size
    assert answered, "vi never emitted ESC[6n -- terminal-size probe not firing"

    # Repaint the status bar (its per-key indicator reveals the geometry).
    session.serial.write(b"x")
    session.serial.flush()
    time.sleep(0.8)
    try:
        buf += session.serial.read(session.serial.in_waiting or 1)
    except OSError:
        pass
    text = buf.decode("utf-8", "ignore")
    # cursor-move rows, excluding the 999;999 probe vi itself emits
    rows = [int(r) for r in re.findall(r"\x1b\[(\d+);\d+H", text) if int(r) < 900]
    assert rows and max(rows) <= 16, (
        f"vi kept the 24-row layout (max cursor row {max(rows or [0])}); "
        "CPR size not applied"
    )

    session.serial.write(b"\x1b:q\n")
    session.serial.flush()
    try:
        session.wait_for_prompt_except_logs(timeout=10)
    except Exception:
        pass


def test_vi_create_modify_file(request):
    session = request.node.stash[session_key]

    # Start from a known-clean slate (/tmp is RAM-backed but the session is
    # shared across tests without a reset, so a prior run could have left it).
    session.write_command(f"rm -f {VI_PATH}")
    session.wait_for_prompt_except_logs()

    # --- create the file in vi -------------------------------------------
    # Opening a non-existent path gives a single empty line with the filename
    # already bound to the buffer, so :wq saves straight to VI_PATH.
    _vi_open(session, VI_PATH)
    _vi_feed(session, "i")                 # normal -> insert mode
    _vi_feed(session, "hello vi")          # type line 1
    _vi_feed(session, ENTER)               # break into a new line
    _vi_feed(session, "second line")       # type line 2
    _vi_feed(session, ESC)                 # insert -> normal mode
    _vi_save_quit(session)

    lines = _cat_lines(session, VI_PATH)
    assert lines == ["hello vi", "second line"], lines

    # --- modify the file in vi -------------------------------------------
    # 1) prepend "MOD " to the first line (gg -> top, i -> insert at col 0)
    # 2) append a brand-new last line (G -> last line, $ -> EOL, a -> append)
    _vi_open(session, VI_PATH)
    _vi_feed(session, "gg")                # jump to the first line
    _vi_feed(session, "i")
    _vi_feed(session, "MOD ")              # prepend
    _vi_feed(session, ESC)
    _vi_feed(session, "G")                 # jump to the last line
    _vi_feed(session, "$")                 # move to end of line
    _vi_feed(session, "a")                 # append after the cursor
    _vi_feed(session, ENTER + "third line")
    _vi_feed(session, ESC)
    _vi_save_quit(session)

    lines = _cat_lines(session, VI_PATH)
    assert lines == ["MOD hello vi", "second line", "third line"], lines

    # leave the slate clean for the next test
    session.write_command(f"rm -f {VI_PATH}")
    session.wait_for_prompt_except_logs()
