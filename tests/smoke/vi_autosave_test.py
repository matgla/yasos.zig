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

# yasvi's crash-recovery autosave on the target. A crash cannot be staged
# from the one serial console (vi owns it until it exits, and every exit
# deletes the autosave), so the shell plants the file a crash would have left
# and vi has to find it, offer it, and :recover it. The writes themselves
# (tmp + fsync + rename, mkdir -p of the cache dir) are run by an idle pause
# and must not report "Autosave failed".

import time

from .conftest import session_key
from .vi_test import ENTER, ESC, _vi_feed

CACHE_DIR = "/root/.cache/yasvi"


def _sh(session, command):
    session.write_command(command)
    return session.wait_for_prompt_except_logs(timeout=10)


def _vi_open_capture(session, path):
    session.write_command(f"vi {path}")
    time.sleep(1.5)  # initscr() + the first full-screen paint
    return session._drain_serial_buffer()


def _vi_keys_capture(session, keys, settle=0.3):
    session.serial.write(keys.encode("utf-8"))
    session.serial.flush()
    time.sleep(settle)
    return session._drain_serial_buffer()


def _vi_quit(session, command):
    session.serial.write((command + ENTER).encode("utf-8"))
    session.serial.flush()
    return session.wait_for_prompt_except_logs(timeout=10)


def test_vi_recovers_autosave_beside_file(request):
    session = request.node.stash[session_key]
    _sh(session, "rm -f /tmp/as.txt /tmp/.as.txt.yasvi-autosave")
    _sh(session, "echo on-disk > /tmp/as.txt")
    _sh(session, "echo crashed-work > /tmp/.as.txt.yasvi-autosave")

    screen = _vi_open_capture(session, "/tmp/as.txt")
    assert "Autosave found" in screen
    _vi_feed(session, ":recover" + ENTER)
    _vi_quit(session, ":wq")

    assert "crashed-work" in _sh(session, "cat /tmp/as.txt")
    listing = " ".join(_sh(session, "ls -a /tmp"))
    assert ".as.txt.yasvi-autosave" not in listing
    _sh(session, "rm -f /tmp/as.txt")


def test_vi_autosave_of_read_only_file_goes_to_home_cache(request):
    # /etc/fstab is on the read-only romfs: its autosave lives under
    # $HOME/.cache/yasvi (HOME comes from the kernel's environment for pid 1)
    # named after the file's absolute path.
    session = request.node.stash[session_key]
    planted = f"{CACHE_DIR}/%etc%fstab.yasvi-autosave"
    _sh(session, f"mkdir -p {CACHE_DIR}")
    _sh(session, f"echo from-home-cache > '{planted}'")
    _sh(session, "rm -f /tmp/fstab_rec.txt")

    screen = _vi_open_capture(session, "/etc/fstab")
    assert "Autosave found" in screen
    _vi_feed(session, ":recover" + ENTER)
    # An edit and an idle pause: vi rewrites the autosave in the cache dir.
    _vi_feed(session, "i")
    _vi_feed(session, "X")
    screen = _vi_keys_capture(session, ESC, settle=3.5)
    screen += _vi_keys_capture(session, "l")  # a repaint shows any message
    assert "Autosave failed" not in screen
    _vi_feed(session, ":w /tmp/fstab_rec.txt" + ENTER)
    _vi_quit(session, ":q")  # a clean exit deletes the autosave

    assert "Xfrom-home-cache" in _sh(session, "cat /tmp/fstab_rec.txt")
    listing = " ".join(_sh(session, f"ls -a {CACHE_DIR}"))
    assert "fstab" not in listing
    _sh(session, "rm -f /tmp/fstab_rec.txt")
