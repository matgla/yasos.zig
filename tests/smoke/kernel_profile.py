"""What the kernel says every process cost, harvested from a test's transcript.

On a ``CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING=y`` build the kernel prints
a per-process profile line for *every* process at exit
(``source/kernel/interrupts/syscall_handlers.zig``), tagged ``[ERR][tprof]``.
Those lines are already interleaved into each smoke test's serial transcript;
this module turns them into per-window totals.

That covers what tcc's own ``-bench`` dump cannot: the compiled test binary,
the shell around it, and -- for the compile itself -- the part of the process
that happens after tcc dumps and *resets* the counters (``perf_dump_print``
takes ``reset=1``), so the two are additive rather than overlapping.

The windows come from the markers the suite already echoes around each phase.
Each marker appears twice in the transcript: once in the shell's echo of the
command, once as the status the command printed. Everything between those two
occurrences is what that phase did.
"""

from dataclasses import dataclass, field
from pathlib import Path
import re


# Kernel per-process totals: syscall count, kernel-side syscall time, the
# handler-body half of it, dynamic-load time, and the bytes and microseconds in
# read()/write(). `top` carries only the three costliest syscalls per process.
SYSPROF_RE = re.compile(
    r"sysprof pid=(?P<pid>\d+) calls=(?P<calls>\d+) us=(?P<us>\d+)"
    r" handler_us=(?P<handler_us>\d+) load_us=(?P<load_us>\d+)"
    r" read=(?P<read_bytes>\d+)/(?P<read_us>\d+)"
    r" write=(?P<write_bytes>\d+)/(?P<write_us>\d+)"
    r" dropped=(?P<dropped>\d+) top=(?P<top>[\d:/,]+)"
)
# Where open() time goes: path resolution, the filesystem walk, and attaching
# the resulting node. The rf_* group is optional so a kernel built before those
# counters existed still matches.
OPENPROF_RE = re.compile(
    r"openprof pid=(?P<pid>\d+) calls=(?P<calls>\d+) misses=(?P<misses>\d+)"
    r" resolve_us=(?P<resolve_us>\d+) lookup_us=(?P<lookup_us>\d+) attach_us=(?P<attach_us>\d+)"
    r"(?: rf_hdrs=(?P<rf_hdrs>\d+) rf_reads=(?P<rf_reads>\d+) rf_allocs=(?P<rf_allocs>\d+)"
    r" rf_hdr_us=(?P<rf_hdr_us>\d+)"
    r" kheap=(?P<kheap_calls>\d+)/(?P<kheap_us>\d+)us"
    r" mount_us=(?P<mount_us>\d+) fsget_us=(?P<fsget_us>\d+)"
    r" walk_us=(?P<walk_us>\d+) node_us=(?P<node_us>\d+))?"
)
# SD block traffic, so write()/close() can be split into the card's own time and
# the filesystem bookkeeping above it.
DISKPROF_RE = re.compile(
    r"diskprof pid=(?P<pid>\d+) writes=(?P<writes>\d+)/(?P<write_blocks>\d+)blk/(?P<write_us>\d+)us"
    r" cardwait=(?P<card_wait_us>\d+)us"
    r" reads=(?P<reads>\d+)/(?P<read_blocks>\d+)blk/(?P<read_us>\d+)us"
)
# mmap/munmap: pages taken from the page pool and the time spent clearing them,
# which is the part that scales with bytes rather than with calls.
POOLPROF_RE = re.compile(
    r"poolprof pid=(?P<pid>\d+) allocs=(?P<allocs>\d+) frees=(?P<frees>\d+)"
    r" pages=(?P<pages>\d+) cleared=(?P<cleared>\d+) max=(?P<max>\d+)"
    r" hits=(?P<hits>\d+) misses=(?P<misses>\d+)"
    r" sram=(?P<sram>\d+) psram=(?P<psram>\d+)"
    r" scan_us=(?P<scan_us>\d+) mark_us=(?P<mark_us>\d+) book_us=(?P<book_us>\d+)"
    r" clear_us=(?P<clear_us>\d+) flookup_us=(?P<flookup_us>\d+) fmark_us=(?P<fmark_us>\d+)"
)

# The clearing cost split by memory tier: the same mmap costs an order of
# magnitude more in PSRAM (~55 MB/s) than in SRAM (~777 MB/s), so the tier a
# page came from matters more than the number of calls.
POOLCLEAR_RE = re.compile(
    r"poolclear pid=(?P<pid>\d+) sram=(?P<sram_bytes>\d+)B/(?P<sram_us>\d+)us"
    r" psram=(?P<psram_bytes>\d+)B/(?P<psram_us>\d+)us"
)
# The shell's own report of a foreground job: wall time and exit code.
RUN_RE = re.compile(r"run pid=(?P<pid>\d+) us=(?P<us>\d+) code=(?P<code>-?\d+)")

# Every line above is emitted through perf.trace, which tags them all the same
# way. Checked before running any regex: a transcript is mostly compiler output
# and program output, and this keeps the scan to one substring test per line.
TRACE_TAG = "tprof"


def _syscall_names():
    """Map syscall id -> name by reading the enum the kernel numbers from.

    The kernel line carries ids, not names: it has no name table and printing
    one from the exit path would cost more serial than the measurement. The
    enum in libc is the single source of those numbers, so parse it rather than
    duplicating the list here, where it would rot the next time one is added.
    """
    header = Path(__file__).resolve().parents[2] / "libs" / "libc" / "sys" / "syscall.h"
    names = {}
    try:
        text = header.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return names
    body = re.search(r"typedef enum SystemCall \{(.*?)\}", text, re.S)
    if body is None:
        return names
    value = 0
    for entry in body.group(1).split(","):
        entry = entry.split("//")[0].strip()
        if not entry:
            continue
        assignment = re.match(r"(\w+)\s*=\s*(\d+)$", entry)
        if assignment:
            value = int(assignment.group(2))
            names[value] = assignment.group(1).removeprefix("sys_")
        elif re.match(r"^\w+$", entry):
            value += 1
            names[value] = entry.removeprefix("sys_")
    return names


SYSCALL_NAMES = _syscall_names()


def syscall_name(number):
    return SYSCALL_NAMES.get(int(number), f"syscall_{number}")


@dataclass
class KernelProfile:
    """Kernel-measured cost of every process that exited inside one window."""

    processes: int = 0
    calls: int = 0
    us: int = 0
    handler_us: int = 0
    load_us: int = 0
    read_bytes: int = 0
    read_us: int = 0
    write_bytes: int = 0
    write_us: int = 0
    dropped: int = 0
    # syscall name -> {"calls": int, "us": int}; only the top three per process
    # reach the serial line, so this ranks the expensive ones and undercounts
    # the tail rather than being a complete histogram.
    syscalls: dict = field(default_factory=dict)

    # open() attribution
    open_calls: int = 0
    open_misses: int = 0
    open_resolve_us: int = 0
    open_lookup_us: int = 0
    open_attach_us: int = 0

    # block layer
    disk_writes: int = 0
    disk_write_blocks: int = 0
    disk_write_us: int = 0
    disk_card_wait_us: int = 0
    disk_reads: int = 0
    disk_read_blocks: int = 0
    disk_read_us: int = 0

    # page pool (mmap/munmap)
    pool_allocs: int = 0
    pool_pages: int = 0
    pool_cleared: int = 0
    pool_clear_us: int = 0

    @property
    def ms(self):
        return self.us / 1000.0

    @property
    def dispatch_us(self):
        """Syscall time outside the handler bodies: entry, exit, the trampoline."""
        return self.us - self.handler_us

    def add(self, other):
        self.processes += other.processes
        self.calls += other.calls
        self.us += other.us
        self.handler_us += other.handler_us
        self.load_us += other.load_us
        self.read_bytes += other.read_bytes
        self.read_us += other.read_us
        self.write_bytes += other.write_bytes
        self.write_us += other.write_us
        self.dropped += other.dropped
        for name, entry in other.syscalls.items():
            bucket = self.syscalls.setdefault(name, {"calls": 0, "us": 0})
            bucket["calls"] += entry["calls"]
            bucket["us"] += entry["us"]
        for name in (
            "open_calls", "open_misses", "open_resolve_us", "open_lookup_us",
            "open_attach_us", "disk_writes", "disk_write_blocks", "disk_write_us",
            "disk_card_wait_us", "disk_reads", "disk_read_blocks", "disk_read_us",
            "pool_allocs", "pool_pages", "pool_cleared", "pool_clear_us",
        ):
            setattr(self, name, getattr(self, name) + getattr(other, name))
        return self

    def to_dict(self):
        return {
            "processes": self.processes,
            "calls": self.calls,
            "ms": round(self.ms, 3),
            "handler_ms": round(self.handler_us / 1000.0, 3),
            "load_ms": round(self.load_us / 1000.0, 3),
            "read_bytes": self.read_bytes,
            "read_ms": round(self.read_us / 1000.0, 3),
            "write_bytes": self.write_bytes,
            "write_ms": round(self.write_us / 1000.0, 3),
            "dropped": self.dropped,
            "syscalls": {
                name: {"calls": entry["calls"], "ms": round(entry["us"] / 1000.0, 3)}
                for name, entry in sorted(
                    self.syscalls.items(), key=lambda item: item[1]["us"], reverse=True
                )
            },
            "open": {
                "calls": self.open_calls,
                "misses": self.open_misses,
                "resolve_ms": round(self.open_resolve_us / 1000.0, 3),
                "lookup_ms": round(self.open_lookup_us / 1000.0, 3),
                "attach_ms": round(self.open_attach_us / 1000.0, 3),
            },
            "disk": {
                "writes": self.disk_writes,
                "write_blocks": self.disk_write_blocks,
                "write_ms": round(self.disk_write_us / 1000.0, 3),
                "card_wait_ms": round(self.disk_card_wait_us / 1000.0, 3),
                "reads": self.disk_reads,
                "read_blocks": self.disk_read_blocks,
                "read_ms": round(self.disk_read_us / 1000.0, 3),
            },
            "pool": {
                "allocs": self.pool_allocs,
                "pages": self.pool_pages,
                "cleared_bytes": self.pool_cleared,
                "clear_ms": round(self.pool_clear_us / 1000.0, 3),
            },
        }


def parse_lines(lines):
    """Total up every kernel profile line in *lines*."""
    profile = KernelProfile()
    for line in lines:
        if TRACE_TAG not in line:
            continue

        match = SYSPROF_RE.search(line)
        if match is not None:
            profile.processes += 1
            profile.calls += int(match.group("calls"))
            profile.us += int(match.group("us"))
            profile.handler_us += int(match.group("handler_us"))
            profile.load_us += int(match.group("load_us"))
            profile.read_bytes += int(match.group("read_bytes"))
            profile.read_us += int(match.group("read_us"))
            profile.write_bytes += int(match.group("write_bytes"))
            profile.write_us += int(match.group("write_us"))
            profile.dropped += int(match.group("dropped"))
            for item in match.group("top").split(","):
                number, _, rest = item.partition(":")
                calls, _, us = rest.partition("/")
                if not us or int(calls) == 0:
                    continue
                bucket = profile.syscalls.setdefault(
                    syscall_name(number), {"calls": 0, "us": 0}
                )
                bucket["calls"] += int(calls)
                bucket["us"] += int(us)
            continue

        match = OPENPROF_RE.search(line)
        if match is not None:
            profile.open_calls += int(match.group("calls"))
            profile.open_misses += int(match.group("misses"))
            profile.open_resolve_us += int(match.group("resolve_us"))
            profile.open_lookup_us += int(match.group("lookup_us"))
            profile.open_attach_us += int(match.group("attach_us"))
            continue

        match = DISKPROF_RE.search(line)
        if match is not None:
            profile.disk_writes += int(match.group("writes"))
            profile.disk_write_blocks += int(match.group("write_blocks"))
            profile.disk_write_us += int(match.group("write_us"))
            profile.disk_card_wait_us += int(match.group("card_wait_us"))
            profile.disk_reads += int(match.group("reads"))
            profile.disk_read_blocks += int(match.group("read_blocks"))
            profile.disk_read_us += int(match.group("read_us"))
            continue

        match = POOLPROF_RE.search(line)
        if match is not None:
            profile.pool_allocs += int(match.group("allocs"))
            profile.pool_pages += int(match.group("pages"))
            profile.pool_cleared += int(match.group("cleared"))
            profile.pool_clear_us += int(match.group("clear_us"))

    return profile


def window(lines, marker):
    """The lines between the echo of a marked command and the status it printed.

    ``marker`` occurs twice: the shell echoes the command (which ends in
    ``echo <marker>$?``) as it is typed, then the command prints the marker with
    its status. Anything in between is that phase's own output -- which excludes
    the harness round trips before it (source hashing spawns processes of its
    own) and the cleanup after it.

    The *last* two occurrences are the ones taken, not the first two. A flaky
    case reruns inside the same transcript, and an attempt that died between
    the echo and the status leaves an odd number of markers behind; anchoring on
    the last status and the echo immediately before it picks the attempt that
    produced the result in both cases, which is also the attempt the surrounding
    wall-clock numbers describe.

    Returns an empty list when the phase did not run, which is the normal case
    for the execute window of a compile-only test.
    """
    marks = [index for index, line in enumerate(lines) if marker in line]
    if len(marks) < 2:
        return []
    return lines[marks[-2] + 1:marks[-1]]


def parse_windows(log_path, markers):
    """Parse one transcript into ``{name: KernelProfile}`` for each named marker.

    *markers* maps a window name to the marker string that brackets it. A
    missing or unreadable transcript yields empty profiles rather than an error:
    this is instrumentation, and it must never be the reason a test fails.
    """
    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as handle:
            lines = handle.readlines()
    except OSError:
        return {name: KernelProfile() for name in markers}
    return {name: parse_lines(window(lines, marker)) for name, marker in markers.items()}
