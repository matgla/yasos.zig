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

"""File timestamps and the wall clock behind them.

Every file on this system used to report mtime 0, so `ls -l` showed 1970 for
romfs, for /tmp and for a file written a second ago alike, and `make` could
never see a prerequisite as newer than its target.  The chain these cover runs
settimeofday(2) -> the kernel's wall clock -> whichever filesystem the path
lands on -> stat(2) -> `ls -l`, and utimensat(2) back the other way.

The clock is set once per boot by the harness (Session._set_target_clock), so
the first test here is also a check on that: if it did not run, every date on
the board is 1970 and everything below is meaningless.
"""

import re
import time

import pytest

from .conftest import session_key

TMPDIR = "/tmp/stamps"

# 2001-09-09T01:46:40Z.  A round epoch value far from anything the harness
# would set, so a date built from it cannot be confused with the real one.
KNOWN_EPOCH = 1000000000
KNOWN_DATE = "2001-09-09"

# `ls -l` renders a timestamp as " %F %H:%M" (toybox ls, via the libc
# strftime), i.e. 2001-09-09 01:46.
LISTING_DATE = re.compile(r"(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})")


def _fresh_dir(session):
    session.write_command("rm -rf " + TMPDIR)
    session.write_command("mkdir -p " + TMPDIR)
    session.write_command("cd " + TMPDIR)


def _epoch(session):
    session.write_command("date +%s")
    out = session.read_until_prompt()
    for token in out.split():
        if token.isdigit():
            return int(token)
    pytest.fail("date +%%s printed no number: %r" % out)


def _listing_line(session, name):
    """The `ls -l` line for *name*, from a listing of just that file."""
    session.write_command("ls -l " + name)
    out = session.read_until_prompt()
    for line in out.splitlines():
        if name.split("/")[-1] in line and LISTING_DATE.search(line):
            return line
    pytest.fail("no dated ls -l line for %s in %r" % (name, out))


def test_clock_was_set_at_boot(request):
    """The harness handed the board a real date; nothing reads 1970."""
    session = request.node.stash[session_key]
    on_target = _epoch(session)
    on_host = int(time.time())

    # Not an equality: the two clocks are read seconds apart, and the target's
    # is the host's plus however long the boot and the tests before this took.
    assert on_target > 1_700_000_000, (
        "target clock reads %d (%s) -- Session._set_target_clock did not run, "
        "or `date` is missing from the rootfs" % (on_target, on_target)
    )
    assert abs(on_target - on_host) < 3600


def test_date_prints_the_clock_it_was_given(request):
    """settimeofday round-trips: set a known instant, read it back."""
    session = request.node.stash[session_key]
    try:
        session.write_command("date -s @%d" % KNOWN_EPOCH)
        session.read_until_prompt()

        read_back = _epoch(session)
        # A few seconds of slack for the command round trip over serial.
        assert KNOWN_EPOCH <= read_back < KNOWN_EPOCH + 60

        session.write_command("date")
        out = session.read_until_prompt()
        assert "2001" in out
        assert "Sep" in out
    finally:
        session.write_command("date -s @%d" % int(time.time()))
        session.read_until_prompt()


def test_a_new_file_carries_the_current_date(request):
    """A ramfs file is stamped from the clock, and `ls -l` shows it."""
    session = request.node.stash[session_key]
    try:
        session.write_command("date -s @%d" % KNOWN_EPOCH)
        session.read_until_prompt()

        _fresh_dir(session)
        session.write_command("echo content > stamped.txt")
        session.read_until_prompt()

        line = _listing_line(session, "stamped.txt")
        assert KNOWN_DATE in line, line
    finally:
        session.write_command("date -s @%d" % int(time.time()))
        session.read_until_prompt()


def test_rewriting_a_file_moves_its_timestamp(request):
    """The property `make` runs on: a later write reads as a later time."""
    session = request.node.stash[session_key]
    _fresh_dir(session)

    session.write_command("date -s @%d" % KNOWN_EPOCH)
    session.read_until_prompt()
    session.write_command("echo first > moving.txt")
    session.read_until_prompt()
    before = _listing_line(session, "moving.txt")

    try:
        # Two hours on, so the change shows in the %H:%M the listing prints
        # rather than needing sub-minute resolution out of `ls`.
        session.write_command("date -s @%d" % (KNOWN_EPOCH + 7200))
        session.read_until_prompt()
        session.write_command("echo second > moving.txt")
        session.read_until_prompt()
        after = _listing_line(session, "moving.txt")

        assert before != after
        before_time = LISTING_DATE.search(before)
        after_time = LISTING_DATE.search(after)
        assert after_time.groups() > before_time.groups(), (before, after)
    finally:
        session.write_command("date -s @%d" % int(time.time()))
        session.read_until_prompt()


def test_touch_creates_without_truncating(request):
    """`touch` on an existing file leaves its contents alone.

    The touch this replaced opened every file with fopen(path, "w"), so it
    emptied whatever it was pointed at -- the opposite of the job.
    """
    session = request.node.stash[session_key]
    _fresh_dir(session)

    session.write_command("echo keep-me > existing.txt")
    session.read_until_prompt()

    session.write_command("touch existing.txt")
    session.read_until_prompt()

    session.write_command("cat existing.txt")
    out = session.read_until_prompt()
    assert "keep-me" in out

    session.write_command("touch created.txt")
    session.read_until_prompt()
    session.write_command("ls")
    out = session.read_until_prompt()
    assert "created.txt" in out.split()


def test_touch_moves_the_modification_time(request):
    """utimensat(2) end to end, through `touch` and back out through `ls`."""
    session = request.node.stash[session_key]
    _fresh_dir(session)

    session.write_command("date -s @%d" % KNOWN_EPOCH)
    session.read_until_prompt()
    session.write_command("echo body > touched.txt")
    session.read_until_prompt()
    before = _listing_line(session, "touched.txt")
    assert KNOWN_DATE in before, before

    try:
        session.write_command("date -s @%d" % (KNOWN_EPOCH + 86400))
        session.read_until_prompt()
        session.write_command("touch touched.txt")
        session.read_until_prompt()

        after = _listing_line(session, "touched.txt")
        assert "2001-09-10" in after, after

        # And the file still holds what it held: touch moved the timestamp
        # and nothing else.
        session.write_command("cat touched.txt")
        assert "body" in session.read_until_prompt()
    finally:
        session.write_command("date -s @%d" % int(time.time()))
        session.read_until_prompt()


def test_touch_on_the_read_only_rootfs_fails(request):
    """romfs has nowhere to put a timestamp, and says so instead of lying.

    A `touch` that silently did nothing would leave anything comparing dates --
    `make`, above all -- believing a file had moved when it had not.
    """
    session = request.node.stash[session_key]
    session.write_command("cd /")
    session.read_until_prompt()

    session.write_command("touch -c /bin/sh")
    out = session.read_until_prompt()
    assert "cannot set times" in out


# The FAT volume the kernel mounts at /mnt (the tcc corpus disk in QEMU, the
# SD card on the board).  An 8.3 upper-case name, because that is what FAT
# short names are and the corpus is addressed that way everywhere else.
FAT_FILE = "/mnt/FSTAMP.TXT"


def test_fat_stamps_and_restamps_a_file(request):
    """The FAT path, which is the one with real work behind it.

    FatFs asks a context-free C callback for the date every time it writes a
    directory entry; the kernel points that at its wall clock at mount
    (`fatfs.rtc_hook`).  Before this the callback returned a fixed 1980, and the
    build was compiled with FF_FS_NORTC on top, so every file the board ever
    wrote to FAT carried the same date -- the reason `make` on a FAT volume
    could not tell a source from the object built out of it.

    Coming back the other way, `touch` goes through f_utime, and FAT's
    two-second second field is why the instants here are chosen on the minute.
    """
    session = request.node.stash[session_key]
    try:
        session.write_command("date -s @%d" % KNOWN_EPOCH)
        session.read_until_prompt()

        session.write_command("echo fat-content > " + FAT_FILE)
        session.wait_for_prompt(timeout=30)
        session.write_command("cat " + FAT_FILE)
        assert "fat-content" in session.wait_for_prompt(timeout=30)

        created = _listing_line(session, FAT_FILE)
        assert KNOWN_DATE in created, created

        # 2010-01-01T00:00:00Z, through utimensat and f_utime.
        session.write_command("date -s @1262304000")
        session.read_until_prompt()
        session.write_command("touch " + FAT_FILE)
        session.wait_for_prompt(timeout=30)

        restamped = _listing_line(session, FAT_FILE)
        assert "2010-01-01 00:00" in restamped, restamped
    finally:
        session.write_command("rm -f " + FAT_FILE)
        session.wait_for_prompt(timeout=30)
        session.write_command("date -s @%d" % int(time.time()))
        session.read_until_prompt()


def test_every_mount_point_in_the_root_listing_has_a_real_date(request):
    """`ls -la /` -- the listing that showed the problem in the first place.

    Every row here crosses into a different filesystem, and each one used to get
    this wrong in its own way: romfs left the three timespecs untouched so `ls`
    rendered whatever was in its buffer, procfs and driverfs zeroed them to
    1970, the FAT volume root returned before it set them, and /tmp could not be
    stat'd at all (its ramfs was handed the empty path and looked for an entry
    literally named ".").  That last one prints as a row of question marks, so
    the test is written against the whole listing rather than one path.
    """
    session = request.node.stash[session_key]
    session.write_command("cd /")
    session.read_until_prompt()
    session.write_command("ls -la /")
    out = session.wait_for_prompt(timeout=30)

    assert "?" not in out, out

    # While we are reading this listing: a symbolic link has to name its own
    # target. `readlinkat` used to be a stub that copied the literal string
    # "/usr/bin/sh" into the caller's buffer, so every link in the rootfs read
    # back as the shell -- including /bin and /lib, which point at usr/bin and
    # usr/lib.
    for line in out.splitlines():
        if not line.startswith("l"):
            continue
        assert "-> /usr/bin/sh" not in line, line
        if line.split()[-3] == "bin":
            assert line.endswith("bin -> usr/bin"), line
        if line.split()[-3] == "lib":
            assert line.endswith("lib -> usr/lib"), line

    dated = 0
    for line in out.splitlines():
        entry = line.split()
        if not entry or entry[-1] in (".", "..", "$"):
            continue
        match = LISTING_DATE.search(line)
        if match is None:
            continue
        dated += 1
        assert match.group(1) != "1970", line
    # /bin /dev /home /lib /mnt /proc /root /tmp /usr, give or take the board.
    assert dated >= 8, out


def test_rootfs_files_are_older_than_files_written_now(request):
    """romfs reports mount time, so the image is older than anything since.

    Not a cosmetic ordering: an on-device build reads headers and libraries out
    of the rootfs, and a rootfs that looked *newer* than the objects built from
    it would make every one of them permanently out of date.

    It is also a real date rather than 1970: the mount happens seconds into a
    boot that has no clock yet, so romfs keeps the *uptime* it was mounted at
    and re-dates it against whatever the clock says when asked (RomFs
    .mount_uptime_us).
    """
    session = request.node.stash[session_key]
    _fresh_dir(session)
    session.write_command("echo now > fresh.txt")
    session.read_until_prompt()

    fresh = LISTING_DATE.search(_listing_line(session, "fresh.txt"))
    rootfs = LISTING_DATE.search(_listing_line(session, "/bin/sh"))
    assert rootfs.group(1) != "1970", rootfs.group(0)
    assert rootfs.groups() <= fresh.groups(), (rootfs.group(0), fresh.group(0))
