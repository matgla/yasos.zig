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

"""The storage layout /etc/fstab sets up at boot (docs/storage.md).

Read-only checks, true on every target: QEMU without a card, where /var and
/home are RAM fallbacks, and a board whose card cardreformat laid out.
Formatting is exercised by apps/fdisk's host tests (`make -C apps/fdisk test`)
and by `scripts/qemu_mount.py --sdcard`, never here -- it would wipe the card
the other suites keep their corpus on.
"""

import pytest

from .conftest import session_key


def _run(session, command):
    session.write_command(command)
    return session.read_until_prompt()


def _mounts(session):
    """{target: (source, type, options)} from /proc/mounts."""
    mounts = {}
    for line in _run(session, "cat /proc/mounts").splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[1].startswith("/"):
            mounts[fields[1]] = (fields[0], fields[2], fields[3])
    return mounts


def test_fstab_mounts_the_layout(request):
    session = request.node.stash[session_key]
    mounts = _mounts(session)
    for target in ("/", "/dev", "/proc", "/var", "/home", "/root", "/tmp"):
        assert target in mounts, (target, mounts)
    assert mounts["/"][1] == "romfs"
    # /root is the card's /home/root, whatever backs /home.
    assert mounts["/root"][:2] == ("/home/root", "bind"), mounts["/root"]
    assert mounts["/tmp"][1] == "tmpfs"
    # A writable /var: the card's ext4 partition, or the RAM fallback without
    # a card.
    assert mounts["/var"][1] in ("ext4", "ramfs"), mounts["/var"]


def test_root_writes_land_in_home_root(request):
    session = request.node.stash[session_key]
    out = _run(session, "echo storage-probe > /root/.storage_probe && cat /home/root/.storage_probe")
    assert "storage-probe" in out
    _run(session, "rm /root/.storage_probe")


def test_umount_refuses_a_busy_mount(request):
    # /root is bound to /home/root, so /home cannot go.
    session = request.node.stash[session_key]
    out = _run(session, "umount /home; echo rc=$?")
    assert "rc=1" in out, out
    assert "busy" in out.lower(), out
    assert "/home" in _mounts(session)


def test_proc_describes_storage(request):
    session = request.node.stash[session_key]
    filesystems = _run(session, "cat /proc/filesystems")
    assert "ext4" in filesystems and "vfat" in filesystems
    assert "major minor" in _run(session, "cat /proc/partitions")


def test_etc_ships_fstab_and_the_layout_script(request):
    session = request.node.stash[session_key]
    out = _run(session, "grep -c LABEL=YAS /etc/fstab; grep -c -- '-p [1-4]' /usr/bin/cardreformat")
    counts = [line.strip() for line in out.splitlines() if line.strip().isdigit()]
    assert counts[:2] == ["4", "4"], out


def test_cardreformat_runs_and_refuses_a_missing_device(request):
    # Run straight from the romfs, by its #! line: the refusal is the part
    # worth checking without wiping a card.
    session = request.node.stash[session_key]
    out = _run(session, "cardreformat -y /dev/no_such_card; echo rc=$?")
    assert "no such device" in out and "rc=1" in out, out


def test_fdisk_lists_the_disk(request):
    # The card on a board, the fatdisk window in QEMU: listing only.
    session = request.node.stash[session_key]
    out = _run(session, "for d in /dev/mmc0 /dev/fatdisk0; do [ -e $d ] && fdisk -l $d; done; echo done")
    if "Disk /dev/" not in out:
        pytest.skip("no disk on this target")
    assert "Disklabel type: dos" in out, out
