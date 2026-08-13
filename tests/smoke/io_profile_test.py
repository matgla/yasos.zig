"""Per-process syscall and IO profile for ordinary programs.

The tcc timing report only sees what tcc reports about itself under -bench,
which answers "where does a compile go" and nothing else. This instrument asks
the same question of the programs the shell runs all day -- ls, cat, echo, vi
-- by reading the kernel's own `sysprof` line, emitted for every process at
exit on a CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING=y build.

Why it matters beyond curiosity: a spawn costs the loader tens of milliseconds
before main() runs, and these programs do little else. If `ls` spends most of
its life in the loader and in read(), then the compile suite's per-test
overhead is not a tcc problem at all and the levers are the loader and the
filesystem, not the compiler.

Measurements, not assertions -- they print and skip rather than fail, so a
full suite run neither pays for them nor can be failed by them:

    scripts/remote_smoke_tui.py --profile --pytest-args \\
        "tests/smoke/io_profile_test.py -m measure -s"
"""

import time

import pytest

from .conftest import session_key
from .kernel_profile import (
    DISKPROF_RE,
    OPENPROF_RE,
    POOLCLEAR_RE,
    POOLPROF_RE,
    RUN_RE,
    SYSPROF_RE,
    syscall_name,
)


pytestmark = pytest.mark.measure


def _format_top(raw):
    parts = []
    for item in raw.split(","):
        ids, _, rest = item.partition(":")
        calls, _, us = rest.partition("/")
        if not us or int(calls) == 0:
            continue
        name = syscall_name(ids)
        parts.append(f"{name}={calls} calls/{int(us) / 1000.0:.2f}ms")
    return "  ".join(parts) if parts else "(none)"


def _log_offset(session):
    """Where the session log ends right now, so a command reads only its own lines."""
    session.file.flush()
    with open(session.log_path, "r", encoding="utf-8", errors="ignore") as handle:
        handle.seek(0, 2)
        return handle.tell()


def _lines_since(session, offset):
    session.file.flush()
    with open(session.log_path, "r", encoding="utf-8", errors="ignore") as handle:
        handle.seek(offset)
        return handle.readlines()


def _profile_since(session, offset):
    """The last exited process's profile in the tail of the log.

    The *last* one because a command line may spawn more than one process (the
    shell's own fork, a pipeline); the one that exits last is the one the
    command was about.
    """
    sysprof = None
    run = None
    pool = None
    clear = None
    opens = None
    disks = None
    for line in _lines_since(session, offset):
        match = SYSPROF_RE.search(line)
        if match:
            sysprof = match
            continue
        match = POOLPROF_RE.search(line)
        if match:
            pool = match
            continue
        match = POOLCLEAR_RE.search(line)
        if match:
            clear = match
            continue
        match = OPENPROF_RE.search(line)
        if match:
            opens = match
            continue
        match = DISKPROF_RE.search(line)
        if match:
            disks = match
            continue
        match = RUN_RE.search(line)
        if match:
            run = match
    if sysprof is None:
        return None
    profile = {
        key: (value if key == "top" else int(value))
        for key, value in sysprof.groupdict().items()
    }
    profile["run_us"] = int(run.group("us")) if run is not None else 0
    profile["pool"] = (
        {key: int(value) for key, value in pool.groupdict().items()}
        if pool is not None
        else None
    )
    profile["clear"] = (
        {key: int(value) for key, value in clear.groupdict().items()}
        if clear is not None
        else None
    )
    # The rf_* counters are an optional group: a kernel built before they
    # existed still matches the line, and their fields come back None.
    profile["disks"] = (
        {key: int(value) for key, value in disks.groupdict().items()}
        if disks is not None
        else None
    )
    profile["opens"] = (
        {key: int(value) if value is not None else 0 for key, value in opens.groupdict().items()}
        if opens is not None
        else None
    )
    return profile


def _report(label, profile):
    if profile is None:
        print(f"  {label:<28} no sysprof line — is this a --profile build?")
        return
    total_us = profile["load_us"] + profile["run_us"]
    syscall_share = (profile["us"] / profile["run_us"] * 100.0) if profile["run_us"] else 0.0
    loader_share = (profile["load_us"] / total_us * 100.0) if total_us else 0.0
    print(
        f"  {label:<28} spawn {total_us / 1000.0:8.2f}ms = "
        f"loader {profile['load_us'] / 1000.0:7.2f}ms ({loader_share:4.1f}%) + "
        f"run {profile['run_us'] / 1000.0:7.2f}ms"
    )
    print(
        f"  {'':<28}   syscalls {profile['us'] / 1000.0:7.2f}ms "
        f"({syscall_share:4.1f}% of run) over {profile['calls']:>5} calls, "
        f"dispatch {(profile['us'] - profile['handler_us']) / 1000.0:.2f}ms"
    )
    print(
        f"  {'':<28}   read {profile['read_bytes']:>8}B in {profile['read_us'] / 1000.0:6.2f}ms   "
        f"write {profile['write_bytes']:>8}B in {profile['write_us'] / 1000.0:6.2f}ms"
        + (f"   dropped {profile['dropped']}" if profile["dropped"] else "")
    )
    print(f"  {'':<28}   top: {_format_top(profile['top'])}")
    disks = profile.get("disks")
    if disks and (disks["writes"] or disks["reads"]):
        print(
            f"  {'':<28}   disk: {disks['writes']} writes / {disks['write_blocks']} blk"
            f" in {disks['write_us'] / 1000.0:.2f}ms (card wait {disks['card_wait_us'] / 1000.0:.2f}ms),"
            f" {disks['reads']} reads / {disks['read_blocks']} blk"
            f" in {disks['read_us'] / 1000.0:.2f}ms"
        )
    opens = profile.get("opens")
    if opens:
        total_us = opens["resolve_us"] + opens["lookup_us"] + opens["attach_us"]
        per_call = (total_us / opens["calls"]) if opens["calls"] else 0.0
        print(
            f"  {'':<28}   open: {opens['calls']} calls ({opens['misses']} found nothing), "
            f"{total_us / 1000.0:.2f}ms ({per_call:.0f}us each) — "
            f"resolve {opens['resolve_us'] / 1000.0:.2f}ms  "
            f"vfs-lookup {opens['lookup_us'] / 1000.0:.2f}ms  "
            f"attach {opens['attach_us'] / 1000.0:.2f}ms"
        )
    pool = profile.get("pool")
    if pool:
        total_us = (
            pool["scan_us"] + pool["mark_us"] + pool["book_us"] + pool["clear_us"]
            + pool["flookup_us"] + pool["fmark_us"]
        )
        per_alloc = (total_us / pool["allocs"]) if pool["allocs"] else 0.0
        served = pool["hits"] + pool["misses"]
        hit_rate = (pool["hits"] / served * 100.0) if served else 0.0
        print(
            f"  {'':<28}   pool: {pool['allocs']} allocs / {pool['frees']} frees, "
            f"{total_us / 1000.0:.2f}ms ({per_alloc:.0f}us per alloc), "
            f"{pool['cleared']}B cleared (max {pool['max']}B), "
            f"sram {pool['sram']} / psram {pool['psram']}"
        )
        print(
            f"  {'':<28}         reuse cache: {pool['hits']}/{served} requests "
            f"({hit_rate:.0f}% hit) served without pool work or a clear"
        )
        clear = profile.get("clear")
        if clear:
            def rate(byte_count, micros):
                return f"{byte_count / micros:.0f} MB/s" if micros else "n/a"

            print(
                f"  {'':<28}         clear: sram {clear['sram_bytes']}B in "
                f"{clear['sram_us'] / 1000.0:.2f}ms ({rate(clear['sram_bytes'], clear['sram_us'])})   "
                f"psram {clear['psram_bytes']}B in {clear['psram_us'] / 1000.0:.2f}ms "
                f"({rate(clear['psram_bytes'], clear['psram_us'])})"
            )
        print(
            f"  {'':<28}         scan {pool['scan_us'] / 1000.0:.2f}ms  "
            f"mark {pool['mark_us'] / 1000.0:.2f}ms  "
            f"book {pool['book_us'] / 1000.0:.2f}ms  "
            f"clear {pool['clear_us'] / 1000.0:.2f}ms  "
            f"free-lookup {pool['flookup_us'] / 1000.0:.2f}ms  "
            f"free-mark {pool['fmark_us'] / 1000.0:.2f}ms"
        )


def _measure(session, label, command, timeout=20):
    offset = _log_offset(session)
    session.write_command(command)
    session.wait_for_prompt_except_logs(timeout=timeout)
    profile = _profile_since(session, offset)
    _report(label, profile)
    return profile


def test_profile_shell_tools(request):
    """ls / cat / echo: the cheapest programs on the system, fully attributed."""
    session = request.node.stash[session_key]
    print("\nPer-process profile (kernel-measured):")
    profiles = {}
    profiles["ls"] = _measure(session, "ls /bin", "ls /bin")
    profiles["cat"] = _measure(session, "cat /usr/hello_script.sh", "cat /usr/hello_script.sh")
    # echo is a shell builtin, so `echo hi` forks nothing; run it through a
    # child shell to get a process whose whole life is one write().
    profiles["echo"] = _measure(session, "sh -c 'echo hi'", "sh -c \"echo hi\"")

    if all(profile is None for profile in profiles.values()):
        pytest.skip("no sysprof lines: build without CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING")


def test_profile_open_cost_by_directory(request):
    """Does an open cost more in a directory with more entries in it?

    The suite's per-open cost (~1.9 ms) is far above what a compile in a small
    directory pays (~336 us), and the difference lines up with where the files
    live: the corpus puts ~1800 gcc sources in one directory. If the filesystem
    walks entries linearly, that is the whole gap -- and the fix is the
    harness's directory layout, not the VFS.

    Each `cat` is one open of the target, so the kernel's openprof line for
    that process is the cost of exactly that lookup.
    """
    session = request.node.stash[session_key]
    # Depth against width. Sharding the corpus cut a directory from ~1685
    # entries to ~51 and the open did not get cheaper, so the cost is not the
    # scan for the entry -- these rows put the same file at depth 1, 2 and 7 to
    # find out whether FatFs is charging per path component instead.
    targets = [
        ("romfs, small dir", "/usr/hello_script.sh"),
        ("fat, depth 1", "/root/io_profile_probe.txt"),
        ("fat, depth 2", "/root/ci/io_profile_probe.txt"),
        ("fat, depth 4 (small dirs)", "/root/ci/a/b/io_profile_probe.txt"),
        ("fat, depth 7, ~51-entry dir", "/root/ci/sources/v2/gcc_torture/execute/09/20021219-1.c"),
        ("fat, depth 5, ~1685-entry dir", "/root/ci/sources/gcc_torture/execute/20020108-1.c"),
        # Misses, which are what a library or include search is made of. The
        # VFS answers a failed lookup by walking the path for a symlink, one
        # stat per component -- unless the filesystem says its format cannot
        # hold one, which FAT does. These rows are that path.
        ("fat, MISS at depth 2", "/root/ci/does_not_exist.txt"),
        ("fat, MISS at depth 7", "/root/ci/sources/v2/gcc_torture/execute/09/does_not_exist.c"),
        ("romfs, MISS at depth 3", "/usr/lib/does_not_exist.so"),
    ]
    for setup in (
        "mkdir -p /root/ci/a/b",
        "echo probe > /root/io_profile_probe.txt",
        "echo probe > /root/ci/io_profile_probe.txt",
        "echo probe > /root/ci/a/b/io_profile_probe.txt",
    ):
        session.write_command(setup)
        session.wait_for_prompt_except_logs(timeout=15)

    print("\nopen() cost by directory (kernel-measured, one cat per row):")
    seen = 0
    # Each path is opened twice in a row. The second open walks the same
    # directory sectors the first one just pulled in, so the pair separates a
    # walk bound on reading the directory off the card (second one much
    # cheaper) from one bound on scanning entries the FAT cache already holds
    # (both the same). That is what decides whether a bigger cache can help.
    targets = [
        (label + suffix, path)
        for label, path in targets
        for suffix in ("", " [again]")
    ]
    for label, path in targets:
        offset = _log_offset(session)
        session.write_command(f"cat {path}")
        session.wait_for_prompt_except_logs(timeout=20)
        profile = _profile_since(session, offset)
        opens = (profile or {}).get("opens")
        if not opens or not opens["calls"]:
            print(f"  {label:<26} no openprof line (missing file, or not a --profile build)")
            continue
        seen += 1
        total_us = opens["resolve_us"] + opens["lookup_us"] + opens["attach_us"]
        # rf_* is romfs-only, so it is zero for the FAT rows; printing it only
        # when non-zero keeps those rows readable and makes it obvious which
        # filesystem answered.
        heap = ""
        if opens["kheap_calls"]:
            heap = (
                f"  [kernel heap: {opens['kheap_calls']} allocs, {opens['kheap_us']}us]"
                f"  [vfs: mount {opens['mount_us']}us, fs.get {opens['fsget_us']}us"
                f" = walk {opens['walk_us']}us + node {opens['node_us']}us]"
            )
        walk = ""
        if opens["rf_hdrs"]:
            walk = (
                f"  [romfs walk: {opens['rf_hdrs']} entries, {opens['rf_reads']} reads, "
                f"{opens['rf_allocs']} name allocs, {opens['rf_hdr_us']}us in entry reads]"
            )
        print(
            f"  {label:<26} {opens['calls']} open(s)  {total_us / opens['calls']:7.0f}us each  "
            f"(resolve {opens['resolve_us']}us, vfs-lookup {opens['lookup_us']}us, "
            f"attach {opens['attach_us']}us){walk}{heap}"
        )

    session.write_command(
        "rm -f /root/io_profile_probe.txt /root/ci/io_profile_probe.txt "
        "/root/ci/a/b/io_profile_probe.txt"
    )
    session.wait_for_prompt_except_logs(timeout=10)
    if not seen:
        pytest.skip("no openprof lines: build without CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING")


def test_profile_vi(request):
    """vi: a curses program, so the write side is the interesting one."""
    session = request.node.stash[session_key]
    path = "/root/ci/io_profile_vi.txt"
    session.write_command("mkdir -p /root/ci")
    session.wait_for_prompt_except_logs(timeout=10)

    offset = _log_offset(session)
    session.write_command(f"vi {path}")
    time.sleep(1.5)  # initscr() + first full-screen paint
    session._drain_serial_buffer()
    session.serial.write(b"ihello from the io profile\x1b")
    session.serial.flush()
    time.sleep(0.5)
    session.serial.write(b":wq\r")
    session.serial.flush()
    session.wait_for_prompt_except_logs(timeout=15)

    print("\nPer-process profile (kernel-measured):")
    profile = _profile_since(session, offset)
    _report("vi (open, insert, :wq)", profile)

    session.write_command(f"rm -f {path}")
    session.wait_for_prompt_except_logs(timeout=10)

    if profile is None:
        pytest.skip("no sysprof lines: build without CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING")


def test_profile_tcc_small_compile(request):
    """A tcc compile through the same lens, for scale against the tools above."""
    session = request.node.stash[session_key]
    source = "/root/ci/io_profile_hello.c"
    session.write_command("mkdir -p /root/ci")
    session.wait_for_prompt_except_logs(timeout=10)
    # echo + redirect, not printf: the device has no printf program, and the
    # shell's echo is a builtin. No backslash escapes anywhere in the source
    # either — whether echo expands them is one more thing that would have to
    # be true for the measurement to happen.
    session.write_command(f"echo 'int puts(const char *s);' > {source}")
    session.wait_for_prompt_except_logs(timeout=10)
    session.write_command(f"echo 'int main(void){{puts(\"hi\");return 0;}}' >> {source}")
    session.wait_for_prompt_except_logs(timeout=10)
    session.write_command(f"cat {source}")
    written = session.wait_for_prompt_except_logs(timeout=10)
    if not any("main" in line for line in written):
        pytest.skip(f"could not stage a source to compile: {written}")

    print("\nPer-process profile (kernel-measured):")
    _measure(session, "tcc -O0 hello.c", f"tcc {source} -o /root/ci/io_profile_hello", timeout=60)
    _measure(session, "the compiled binary", "/root/ci/io_profile_hello", timeout=30)

    session.write_command(f"rm -f {source} /root/ci/io_profile_hello")
    session.wait_for_prompt_except_logs(timeout=10)
