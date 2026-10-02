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

# Insert-mode word completion in the bundled vi (apps/yasvi, completion.c):
# Ctrl-N / Ctrl-P cycle the candidates for the word before the cursor, Ctrl-E
# puts the typed word back. As in vi_test.py the result is checked in the saved
# file, not on the screen -- except the menu, whose other entries only ever
# appear in vi's output.

import time

from .conftest import session_key
from .vi_test import ESC, ENTER, _cat_lines, _vi_feed, _vi_open, _vi_save_quit

CTRL_E = "\x05"
CTRL_N = "\x0e"
CTRL_P = "\x10"

ZIG_PATH = "/tmp/vi_complete.zig"


def _vi_feed_output(session, keys, settle=0.6):
    """Like _vi_feed, but return what vi painted in response."""
    session.serial.write(keys.encode("utf-8"))
    session.serial.flush()
    time.sleep(settle)
    return session._drain_serial_buffer()


def test_vi_completes_zig_words_and_builtins(request):
    session = request.node.stash[session_key]
    session.write_command(f"rm -f {ZIG_PATH}")
    session.wait_for_prompt_except_logs()
    for line in ['const std = @import("std");',
                 "pub fn counter_value() u32 {",
                 "    return 1;",
                 "}"]:
        session.write_command(f"echo '{line}' >> {ZIG_PATH}")
        session.wait_for_prompt_except_logs()

    try:
        _vi_open(session, ZIG_PATH)
        # A new last line: yasvi has no normal-mode 'o', so append at the end
        # of the last line and break it.
        _vi_feed(session, "G")
        _vi_feed(session, "$")
        _vi_feed(session, "a")
        _vi_feed(session, ENTER)
        # A word from the buffer.
        _vi_feed(session, "const x = coun")
        _vi_feed(session, CTRL_N)
        _vi_feed(session, "();" + ENTER)
        # A builtin: "@int" has several, so the menu lists the ones Ctrl-N has
        # not put in the line yet.
        _vi_feed(session, "_ = @int")
        painted = _vi_feed_output(session, CTRL_N)
        _vi_feed(session, "(x);" + ENTER)
        # A keyword, and Ctrl-P from the other end then Ctrl-E back to "comp".
        _vi_feed(session, "comp")
        _vi_feed(session, CTRL_P)
        _vi_feed(session, CTRL_E)
        _vi_feed(session, "_done" + ESC)
    finally:
        lines = _vi_save_quit(session)

    assert "@intCast" in painted, f"completion menu not drawn: {painted!r}"
    assert "@intFromBool" in painted, f"completion menu not drawn: {painted!r}"

    lines = _cat_lines(session, ZIG_PATH)
    assert "const x = counter_value();" in lines, lines
    assert "_ = @intCast(x);" in lines, lines
    assert "comp_done" in lines, lines
