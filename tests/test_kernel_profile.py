"""Harvesting the kernel's per-process profile lines out of a test transcript."""

from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke.kernel_profile import KernelProfile, parse_lines, parse_windows, window


COMPILE_MARKER = "__COMPILE_STATUS__:"
EXIT_MARKER = "__EXIT_STATUS__:"

# A transcript in the shape the suite produces: the shell echoes each command
# (which itself ends in `echo <marker>$?`), the kernel interleaves a profile
# line per process exit, then the command prints the marker with its status.
TRANSCRIPT = f"""\
$ sha256sum /root/ci/sources/v2/tests2/00_assignment.c
[ERR][tprof] sysprof pid=2 calls=40 us=9999 handler_us=9000 load_us=1000 read=100/50 write=0/0 dropped=0 top=18:40/50,0:0/0,0:0/0
9f86d0 /root/ci/sources/v2/tests2/00_assignment.c
$ tcc -bench 00_assignment.c -o /tmp/00_assignment; compile_status=$?; echo {COMPILE_MARKER}$compile_status
[ERR][tprof] sysprof pid=3 calls=169 us=8750 handler_us=8726 load_us=4053 read=26985/864 write=1460/1781 dropped=0 top=16:9/2633,15:9/2488,20:16/1781
[ERR][tprof] openprof pid=3 calls=9 misses=1 resolve_us=109 lookup_us=991 attach_us=127 rf_hdrs=136 rf_reads=140 rf_allocs=2 rf_hdr_us=289 kheap=66/111us mount_us=60 fsget_us=993 walk_us=482 node_us=71
[ERR][tprof] diskprof pid=3 writes=5/7blk/4460us cardwait=6us reads=1/4blk/276us
[ERR][tprof] poolprof pid=3 allocs=12 frees=11 pages=340 cleared=1392640 max=340 hits=3 misses=9 sram=40 psram=300 scan_us=10 mark_us=20 book_us=30 clear_us=25000 flookup_us=5 fmark_us=6
{COMPILE_MARKER}0
$ /tmp/00_assignment; echo {EXIT_MARKER}$?
[ERR][tprof] sysprof pid=4 calls=10 us=500 handler_us=480 load_us=1200 read=0/0 write=37/29 dropped=0 top=20:1/29,34:2/52,0:0/0
{EXIT_MARKER}0
$ rm -f /tmp/00_assignment
[ERR][tprof] sysprof pid=5 calls=10 us=4273 handler_us=4271 load_us=2212 read=0/0 write=0/0 dropped=0 top=21:2/3702,23:4/517,34:2/52
"""


def _write_transcript(tmp_path, text=TRANSCRIPT):
    path = tmp_path / "test_00_assignment.txt"
    path.write_text(text)
    return path


def test_windows_exclude_the_harness_processes(tmp_path):
    """The source hash before the compile and the `rm` after the run are harness
    work: counting either as OS cost of the test would inflate exactly the
    number an OS change is judged by."""
    profiles = parse_windows(
        _write_transcript(tmp_path),
        {"compile": COMPILE_MARKER, "execute": EXIT_MARKER},
    )

    assert profiles["compile"].processes == 1
    assert profiles["compile"].us == 8750
    assert profiles["compile"].calls == 169
    assert profiles["execute"].processes == 1
    assert profiles["execute"].us == 500
    # 9999 (sha256sum) and 4273 (rm) are outside both windows.
    assert profiles["compile"].us + profiles["execute"].us == 9250


def test_syscall_ids_are_resolved_to_names(tmp_path):
    profiles = parse_windows(
        _write_transcript(tmp_path),
        {"compile": COMPILE_MARKER, "execute": EXIT_MARKER},
    )

    syscalls = profiles["compile"].syscalls
    assert syscalls["close"] == {"calls": 9, "us": 2633}
    assert syscalls["open"] == {"calls": 9, "us": 2488}
    assert syscalls["write"] == {"calls": 16, "us": 1781}
    # `0:0/0` pads the top-three list when a process made fewer than three
    # kinds of call; counting it would invent a syscall 0.
    assert "syscall_0" not in syscalls


def test_open_disk_and_pool_attribution_is_kept(tmp_path):
    compile_profile = parse_windows(
        _write_transcript(tmp_path),
        {"compile": COMPILE_MARKER, "execute": EXIT_MARKER},
    )["compile"]

    assert compile_profile.open_calls == 9
    assert compile_profile.open_misses == 1
    assert compile_profile.open_lookup_us == 991
    assert compile_profile.disk_writes == 5
    assert compile_profile.disk_write_blocks == 7
    assert compile_profile.disk_write_us == 4460
    assert compile_profile.disk_card_wait_us == 6
    assert compile_profile.pool_pages == 340
    assert compile_profile.pool_clear_us == 25000


def test_a_compile_only_test_has_an_empty_execute_window(tmp_path):
    text = TRANSCRIPT.split(f"$ /tmp/00_assignment")[0]
    profiles = parse_windows(
        _write_transcript(tmp_path, text),
        {"compile": COMPILE_MARKER, "execute": EXIT_MARKER},
    )

    assert profiles["compile"].processes == 1
    assert profiles["execute"] == KernelProfile()


def test_a_missing_transcript_yields_empty_profiles_rather_than_raising(tmp_path):
    profiles = parse_windows(
        tmp_path / "never_written.txt",
        {"compile": COMPILE_MARKER, "execute": EXIT_MARKER},
    )

    assert profiles["compile"] == KernelProfile()
    assert profiles["execute"] == KernelProfile()


def test_an_unclosed_window_is_reported_as_empty():
    """A test that was aborted mid-compile echoes the command but never prints
    the status. Taking "everything after the echo" would then swallow the rest
    of the run, including the next test's processes."""
    lines = [
        f"$ tcc x.c; echo {COMPILE_MARKER}$?\n",
        "[ERR][tprof] sysprof pid=3 calls=1 us=1 handler_us=1 load_us=0"
        " read=0/0 write=0/0 dropped=0 top=15:1/1\n",
    ]

    assert window(lines, COMPILE_MARKER) == []
    assert parse_lines(window(lines, COMPILE_MARKER)) == KernelProfile()


def test_a_rerun_reports_the_attempt_that_produced_the_result():
    """A flaky case reruns into the same transcript, and an attempt that died
    between the echo and the status leaves an odd number of markers. Both are
    resolved by anchoring on the last status, which is the attempt the case's
    wall-clock numbers describe too."""
    lines = [
        f"$ tcc x.c; echo {COMPILE_MARKER}$?\n",                     # attempt 1 echo
        "[ERR][tprof] sysprof pid=3 calls=1 us=111 handler_us=1 load_us=0"
        " read=0/0 write=0/0 dropped=0 top=15:1/1\n",
        f"$ tcc x.c; echo {COMPILE_MARKER}$?\n",                     # attempt 2 echo
        "[ERR][tprof] sysprof pid=4 calls=1 us=222 handler_us=1 load_us=0"
        " read=0/0 write=0/0 dropped=0 top=15:1/1\n",
        f"{COMPILE_MARKER}0\n",
    ]

    assert parse_lines(window(lines, COMPILE_MARKER)).us == 222


def test_profiles_add_up_across_tests():
    a = KernelProfile(processes=1, calls=10, us=100, syscalls={"open": {"calls": 2, "us": 60}})
    b = KernelProfile(processes=1, calls=5, us=50, syscalls={"open": {"calls": 1, "us": 20}})

    total = KernelProfile().add(a).add(b)

    assert total.processes == 2
    assert total.calls == 15
    assert total.us == 150
    assert total.syscalls == {"open": {"calls": 3, "us": 80}}
    # Adding must not mutate the operands: the suite total is accumulated over
    # every case, and a shared dict would grow each case's own breakdown too.
    assert a.syscalls == {"open": {"calls": 2, "us": 60}}
