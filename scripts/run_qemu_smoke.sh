#!/bin/bash
#
# run_qemu_smoke.sh — build the yasos.zig kernel for QEMU (mps2-an505 / Cortex-M33)
# and run the pytest smoke suite against it. No hardware, no OpenOCD, no SSH.
#
# The smoke Session connects to QEMU's UART over a PTY (see
# tests/smoke/framework/qemu.py); it is activated purely by exporting
# YASOS_QEMU_KERNEL, so the existing tests run unmodified.
#
# Usage:
#   scripts/run_qemu_smoke.sh [options] [pytest args...]
#
# Options:
#   --no-build         Skip configure/build; use the existing kernel ELF.
#   --rebuild-rootfs   Regenerate rootfs.img (needed when userspace changed).
#   --fast             Build the kernel -Doptimize=ReleaseFast instead of the
#                      default ReleaseSafe (which keeps safety checks on).
#   --safe             Build -Doptimize=ReleaseSafe (the default; explicit form).
#   --an505            Use the older MPS2-AN505 board (implies --no-map-corpus;
#                      its 1 MB fatdisk cannot hold the corpus).
#   --no-map-corpus    Push the sources over ZMODEM instead of mapping them into
#                      the file backing guest RAM.
#   --preserve-state   Keep whatever the guest wrote to the mapped disk across
#                      qemu relaunches, instead of restoring the pristine corpus
#                      image before each one.
#   --opt-levels LEVELS
#                      tcc -O levels the smoke suites run at (default
#                      "-O0 -O1 -O2"). Every suite -- tests2, ir_tests and
#                      gcc-torture -- runs once per level, so a single level is
#                      roughly a third of the wall time. Space- or
#                      comma-separated: --opt-levels -O0, --opt-levels '-O0 -O2'.
#                      Overrides YASOS_SMOKE_TCC_OPT_LEVELS.
#   -h, --help         Show this help.
#
# Any non-option arguments are passed through to pytest. With none, the default
# set is the core target tests plus the tcc suites:
#   cd_test.py ls_test.py ps_test.py shell_test.py smp_test.py yaff_arch_test.py
#   tcc_test.py tcc_suite_test.py
# The tcc tests currently FAIL (known tinycc bug + a serial-upload corruption on
# QEMU) and are enabled so they run as fixes land. Pass files to override, e.g.
#   scripts/run_qemu_smoke.sh tcc_suite_test.py -k 00_assignment
# Run the whole suite with:  scripts/run_qemu_smoke.sh .
# Runs in parallel by default (one QEMU per pytest-xdist worker, using all CPUs
# via -n auto). Override the worker count by passing your own -n:
#   scripts/run_qemu_smoke.sh . -n 4
# Disable parallelism with -n 0 or YASOS_SMOKE_XDIST=0.
# Note: the per-test timing/profiling summaries are skipped under -n (they
# aggregate in-process), and pytest's -s output interleaves across workers.
# Output is one line per test (pytest -v, added unless you pass your own -q/-v),
# each carrying a [n/total] counter and the test's wall time, so a long run
# streams progress instead of sitting on a single unterminated progress line.
#
# The run happens in two phases. Everything runs in parallel except the tests
# named in tests/smoke/heavy_tests.txt, which run serially afterwards -- see
# that file for what "heavy" means, how it was measured, and why the guest's
# memory rather than qemu's is what decides it. Each phase writes its own log
# and is printed from it afterwards, so the two do not interleave and the whole
# thing survives being piped somewhere that truncates:
#   .cache/qemu_smoke_phase_logs/pytest_parallel.log
#   .cache/qemu_smoke_phase_logs/pytest_serial.log
# Both are copied into .cache/qemu_smoke_logs/ at the end, next to the per-test
# logs they refer to.
#
# YASOS_SMOKE_MEM_REPORT=<dir> records each test's peak guest memory (and qemu's
# peak RSS beside it) to <dir>/<worker>.tsv, which is how heavy_tests.txt is
# refreshed. Off by default -- it costs two target commands per test.
#
# Logs: each run's per-test session logs, logs/failed/, and the qemu process
# logs are collected into .cache/qemu_smoke_logs/ (analogous to the remote
# runner's .cache/remote_smoke_logs/); cleared and repopulated every run.
#
# The GCC torture smoke tests (tcc_suite_test.py gcc_compile/gcc_execute) are
# enabled by default; the gcc-testsuite submodule under libs/tinycc is fetched
# (shallow) on first use. Disable with YASOS_SMOKE_ENABLE_GCC_TORTURE=0.
#
# Environment overrides (consumed by tests/smoke/framework/qemu.py):
#   YASOS_QEMU_BIN, YASOS_QEMU_MACHINE, YASOS_QEMU_CPU,
#   YASOS_QEMU_EXTRA_ARGS, YASOS_QEMU_BOOT_TIMEOUT
#   YASOS_QEMU_OPTIMIZE   zig optimize mode for the build (default ReleaseSafe;
#                         --fast selects ReleaseFast)
#   YASOS_SMOKE_ENABLE_GCC_TORTURE   default 1 here; set 0 to skip GCC torture
#   YASOS_SMOKE_XDIST     pytest-xdist worker count (default auto = all CPUs);
#                         set 0 to run serially
#   YASOS_SMOKE_TCC_OPT_LEVELS   tcc -O levels to exercise across all suites
#                         (default "-O0 -O1 -O2"); e.g. set "-O0" for one level
#   YASOS_SMOKE_ANNOUNCE_AFTER   print a "RUNNING <elapsed>" line once a test has
#                         been in flight this long (default 1s; 0 disables).
#                         Serial runs only -- ignored under -n/xdist, which
#                         already prints a line per test start.
#   YASOS_SMOKE_ANNOUNCE_EVERY   repeat that line every N seconds while the test
#                         keeps running (default 30s; 0 = announce once)
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

# Default board: MPS3-AN524. Its DDR is 2 GB, which buys the 16 MB fatdisk the
# mapped corpus needs (see --map-corpus below) and removes the RAM ceiling the
# an505 hits -- there, /root is a RamFs in a 4 MB pool, and pushing the corpus
# into it panicked the kernel. --an505 selects the old board.
DEFCONFIG="configs/qemu_mps3_an524_defconfig"
QEMU_MACHINE="mps3-an524"
# QEMU models the SSE-200's CPU0 without an FPU by default; the kernel enables
# CP10/CP11 in crt_init and would take a NOCP UsageFault on its first FP
# instruction without this. CPU1 is given the same treatment so the two cores
# are identical: with CONFIG_PROCESS_SMP the kernel brings core 1 up through the
# same crt path, and a secondary core that differs from core 0 is a difference
# that would only ever surface as a fault somewhere unrelated.
#
# Left on QEMU's default multi-threaded TCG deliberately, i.e. one host thread
# per emulated core. `-accel tcg,thread=single` was tried as a workaround for a
# boot stall and is the wrong answer twice over: round-robin TCG never runs the
# cores at the same instant, so the kernel's cross-core self-test stops
# detecting anything -- with the lock deliberately removed it still reported a
# pass -- and it makes a contended lock crawl at about 140 sections a second.
# The stall itself is fixed in the kernel: source/kernel/smp.zig's self-test no
# longer blocks on a lock.
QEMU_EXTRA="-global sse-200.CPU0_FPU=on -global sse-200.CPU1_FPU=on"
MAP_CORPUS=1
PRESERVE_STATE=0
# Default to ReleaseSafe so safety checks (overflow, bounds, null-unwrap) stay on
# while running the suite; --fast switches to ReleaseFast. An explicit
# YASOS_QEMU_OPTIMIZE wins as the default but is still overridden by --fast.
OPTIMIZE="${YASOS_QEMU_OPTIMIZE:-ReleaseSafe}"
KERNEL="$REPO_ROOT/zig-out/bin/yasos_kernel"
VENV="$REPO_ROOT/.qemu_smoke_venv"
SMOKE_DIR="$REPO_ROOT/tests/smoke"
# Collected per-run logs land here, analogous to the remote runner's
# .cache/remote_smoke_logs/. Cleared and repopulated on every run.
QEMU_SMOKE_LOGS_DIR="$REPO_ROOT/.cache/qemu_smoke_logs"

DO_BUILD=1
REBUILD_ROOTFS=0
OPT_LEVELS="${YASOS_SMOKE_TCC_OPT_LEVELS:-}"
PYTEST_ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-build) DO_BUILD=0; shift ;;
        --rebuild-rootfs) REBUILD_ROOTFS=1; shift ;;
        --fast) OPTIMIZE="ReleaseFast"; shift ;;
        --safe) OPTIMIZE="ReleaseSafe"; shift ;;
        --opt-levels)
            [ "$#" -ge 2 ] || { echo "error: --opt-levels needs a value" >&2; exit 2; }
            OPT_LEVELS="$2"; shift 2
            # A space-separated value arrives as several arguments when the
            # caller's quoting is lost (make -> run_container.sh). Absorb them
            # here; otherwise they would fall through to pytest as bad options.
            while [ "$#" -gt 0 ] && [ "${1#-O}" != "$1" ]; do
                OPT_LEVELS="$OPT_LEVELS $1"; shift
            done ;;
        --opt-levels=*) OPT_LEVELS="${1#*=}"; shift ;;
        --an505)
            DEFCONFIG="configs/qemu_mps2_an505_defconfig"
            QEMU_MACHINE="mps2-an505"; QEMU_EXTRA=""; MAP_CORPUS=0
            shift ;;
        --no-map-corpus) MAP_CORPUS=0; shift ;;
        --preserve-state) PRESERVE_STATE=1; shift ;;
        -h|--help) sed -n '2,77p' "$0"; exit 0 ;;
        --) shift; while [ "$#" -gt 0 ]; do PYTEST_ARGS+=("$1"); shift; done ;;
        *) PYTEST_ARGS+=("$1"); shift ;;
    esac
done

# Accept the comma form too (it is what survives make/run_container.sh's
# unquoted command expansion) and report it the way the suites will read it.
OPT_LEVELS="${OPT_LEVELS//,/ }"

if [ "${#PYTEST_ARGS[@]}" -eq 0 ]; then
    # Core target tests plus the tcc suites. The tcc tests are expected to FAIL
    # for now (known tinycc miscompiles + a serial-upload corruption on QEMU);
    # they are enabled here so they run as fixes land. Override by passing files.
    PYTEST_ARGS=(cd_test.py ls_test.py ps_test.py shell_test.py smp_test.py yaff_arch_test.py tcc_test.py tcc_suite_test.py)
fi

if [ "$DO_BUILD" -eq 1 ]; then
    echo ">> Configuring: $DEFCONFIG"
    zig build defconfig -Ddefconfig_file="$DEFCONFIG"

    # rootfs.img alone is not enough to call the rootfs "built": some tests read
    # host-side artifacts straight out of the staging tree build_rootfs.sh
    # populates (yaff_arch_test.py patches rootfs/usr/bin/hello). A tree that was
    # cleaned after the image was produced keeps rootfs.img but loses the staging
    # dir, so check for a staged binary too rather than just the image.
    ROOTFS_DONOR="$REPO_ROOT/rootfs/usr/bin/hello"
    if [ ! -f "$REPO_ROOT/rootfs.img" ] || [ ! -f "$ROOTFS_DONOR" ] || [ "$REBUILD_ROOTFS" -eq 1 ]; then
        if [ -f "$REPO_ROOT/rootfs.img" ] && [ ! -f "$ROOTFS_DONOR" ] && [ "$REBUILD_ROOTFS" -eq 0 ]; then
            echo ">> rootfs.img exists but the rootfs/ staging tree is missing; rebuilding both"
        fi
        echo ">> Building rootfs.img"
        # --no-kernel: this script runs its own `zig build` below, so skip
        # build_rootfs's built-in kernel rebuild to avoid a redundant build.
        ./build_rootfs.sh -c -o rootfs.img --no-kernel
    else
        echo ">> Reusing existing rootfs.img (pass --rebuild-rootfs to regenerate)"
    fi

    echo ">> Building kernel: -Doptimize=$OPTIMIZE"
    zig build -Doptimize="$OPTIMIZE"
fi

if [ ! -f "$KERNEL" ]; then
    echo "error: kernel ELF not found: $KERNEL" >&2
    echo "       build it first (omit --no-build)." >&2
    exit 1
fi

# Minimal venv: QEMU mode needs only pyserial + pytest (no pyudev/pyocd).
if [ ! -x "$VENV/bin/python" ]; then
    echo ">> Creating venv: $VENV"
    python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --disable-pip-version-check \
    pyserial==3.5 pytest==8.4.0 pytest-rerunfailures==14.0 pytest-xdist==3.8.0

# GCC torture smoke tests run by default; pass YASOS_SMOKE_ENABLE_GCC_TORTURE=0
# to skip them. The test sources live in the gcc-testsuite submodule nested
# inside libs/tinycc, which points at the whole gcc repo — so instead of a full
# submodule clone (~1.3 GB, minutes) we fetch only gcc.c-torture sparsely (~16
# MB, seconds) via download_gcc_tests.sh on first use. A user-provided
# GCC_TORTURE_PATH points at an external checkout, so no fetch is needed then.
# Exercise all optimization levels under QEMU by default. This iterates every
# suite (tests2, ir_tests, gcc-torture) at -O0/-O1/-O2 — tests2/ir_tests ids get
# tagged [-ON] when more than one level is configured. Override with a custom
# list (space/comma separated) via --opt-levels or YASOS_SMOKE_TCC_OPT_LEVELS.
export YASOS_SMOKE_TCC_OPT_LEVELS="${OPT_LEVELS:--O0 -O1 -O2}"

export YASOS_SMOKE_ENABLE_GCC_TORTURE="${YASOS_SMOKE_ENABLE_GCC_TORTURE:-1}"
case "$YASOS_SMOKE_ENABLE_GCC_TORTURE" in
    1|true|yes|on)
        GCC_TORTURE_DIR="$REPO_ROOT/libs/tinycc/tests/gcctestsuite/gcc-testsuite/gcc/testsuite/gcc.c-torture"
        if [ -z "${GCC_TORTURE_PATH:-}" ] && [ ! -d "$GCC_TORTURE_DIR" ]; then
            echo ">> Fetching gcc-torture tests (sparse + partial, ~16 MB)"
            bash "$REPO_ROOT/libs/tinycc/tests/gcctestsuite/download_gcc_tests.sh"
        fi
        ;;
esac

# Run one QEMU per pytest-xdist worker in parallel by default, using all
# available CPUs. Override the worker count by passing your own -n (e.g. -n 4),
# or disable parallelism with -n 0 / YASOS_SMOKE_XDIST=0.
XDIST_DEFAULT="${YASOS_SMOKE_XDIST:-auto}"
have_n=0
for arg in "${PYTEST_ARGS[@]}"; do
    case "$arg" in
        -n|-n[0-9]*|-nauto|-nlogical|--numprocesses|--numprocesses=*) have_n=1; break ;;
    esac
done
if [ "$have_n" -eq 0 ] && [ "$XDIST_DEFAULT" != "0" ]; then
    PYTEST_ARGS+=(-n "$XDIST_DEFAULT")
fi

# -v rather than the default dot progress, same as tests/smoke/run_tests.sh does
# for the hardware runner: without it pytest (and xdist) keeps a single progress
# line open for minutes at a time, so every line-oriented reader -- the CI log
# viewer, `tee`, a pager -- shows nothing while the suite grinds through a
# module, and a run that is actually alive looks hung. -v gives one line per
# test, carrying the [n/total] counter and wall time conftest.py appends in
# pytest_report_teststatus; serially it also lets progress.py's RUNNING
# announcer close the pending line while a slow test is still in flight.
# Skipped if the caller already chose a verbosity (-q, -vv, ...).
have_verbosity=0
for arg in "${PYTEST_ARGS[@]}"; do
    case "$arg" in
        -v*|-q*|--verbose*|--quiet*|--verbosity*) have_verbosity=1; break ;;
    esac
done
if [ "$have_verbosity" -eq 0 ]; then
    PYTEST_ARGS+=(-v)
fi

# stdout here is a pipe, not a tty (podman without -t, then the CI runner), so
# python would block-buffer anything pytest does not explicitly flush -- which
# defeats the per-test lines above.
export PYTHONUNBUFFERED=1

export YASOS_QEMU_KERNEL="$KERNEL"
export YASOS_QEMU_MACHINE="$QEMU_MACHINE"
[ -n "$QEMU_EXTRA" ] && export YASOS_QEMU_EXTRA_ARGS="$QEMU_EXTRA"

# Put the source corpus on the device by writing it into the file that backs
# guest RAM, rather than sending it over the UART.
#
# The fatdisk window is a fixed slice of that file, so this is a host-side file
# write; the guest just mounts it at /mnt. Worth the machinery because the disk
# is RAM-backed and reformatted on every boot while the harness relaunches qemu
# between tests -- so the ZMODEM alternative re-sends 4.13 MiB per relaunch, and
# that dominates a run. With the corpus already there the manifest needs no
# device round trip either, which is what TRUST=1 says.
if [ "$MAP_CORPUS" -eq 1 ]; then
    FATDISK_DIR="$REPO_ROOT/.cache/qemu_smoke_fatdisk"
    mkdir -p "$FATDISK_DIR"
    if [ ! -x "$REPO_ROOT/scripts/fatimg/fatimg" ]; then
        echo ">> Building fatimg"
        bash "$REPO_ROOT/scripts/fatimg/build.sh"
    fi
    echo ">> Building corpus FAT image"
    "$VENV/bin/python" "$REPO_ROOT/scripts/build_smoke_fatdisk.py" \
        --backing "$FATDISK_DIR/seed.bin" --image "$FATDISK_DIR/corpus.img"
    # seed.bin is only a scratch target for the builder; each worker gets its own
    # backing file, seeded from corpus.img by framework/qemu.py.
    rm -f "$FATDISK_DIR/seed.bin"
    export YASOS_QEMU_RAM_BACKING_DIR="$FATDISK_DIR"
    export YASOS_QEMU_FATDISK_IMAGE="$FATDISK_DIR/corpus.img"
    export YASOS_SMOKE_SOURCES_ROOT="/mnt/ci/sources/v2"
    export YASOS_SMOKE_SOURCE_MANIFEST_TRUST=1
fi
export YASOS_QEMU_PRESERVE_STATE="$PRESERVE_STATE"

echo ">> Running smoke tests on QEMU ($(basename "$KERNEL") on $QEMU_MACHINE," \
     "opt levels: $YASOS_SMOKE_TCC_OPT_LEVELS, gcc-torture: $YASOS_SMOKE_ENABLE_GCC_TORTURE)"
cd "$SMOKE_DIR"

# Start each run with an empty logs dir so the collected set reflects only this
# run (mirrors the remote runner clearing the device's logs/ before a run).
# A run accumulates thousands of per-test files in this one flat directory; on
# btrfs (and NFS/overlayfs) rm can intermittently fail with "Directory not
# empty" when its own readdir races the unlinks and the final rmdir then sees
# leftover entries. Retry a few times before giving up — a second pass clears it.
for _attempt in 1 2 3 4 5; do
    rm -rf "$SMOKE_DIR/logs" && break
    [ "$_attempt" = 5 ] && { echo "error: could not clear $SMOKE_DIR/logs" >&2; exit 1; }
    sleep 0.2
done

# Two phases: everything in parallel, then the memory-heavy tests on their own.
#
# Guest RAM is a 2 GB file-backed mapping, and what a test costs the host is how
# much of it the guest touches. Most tests touch little and 32 of them fit side
# by side; a few touch enough that running them together pushes the host into
# reclaim, and a starved guest fails as a *boot timeout*, which reads like a
# target bug rather than a memory one. tests/smoke/heavy_tests.txt names those,
# and they run with parallelism off.
#
# Both phases write to their own log file and are printed from it rather than
# streamed straight to the terminal. That is what makes the result readable
# afterwards: `tee` would interleave the two phases, and a run whose output is
# only ever a pipe loses everything the moment something upstream truncates it.
# The files stay behind for grepping.
# Deliberately NOT inside QEMU_SMOKE_LOGS_DIR: that directory is wiped and
# repopulated from tests/smoke/logs after the run, which would delete these.
PHASE_LOG_DIR="${YASOS_SMOKE_PHASE_LOG_DIR:-$REPO_ROOT/.cache/qemu_smoke_phase_logs}"
rm -rf "$PHASE_LOG_DIR"
mkdir -p "$PHASE_LOG_DIR"
PARALLEL_LOG="$PHASE_LOG_DIR/pytest_parallel.log"
SERIAL_LOG="$PHASE_LOG_DIR/pytest_serial.log"

# A caller's own -m has to be combined with the phase selector rather than
# replaced by it: pytest keeps only the last -m, so appending one would silently
# drop theirs (`-m measure` would start running the whole suite).
USER_MARK=""
PHASE_ARGS=()
skip_next=0
for arg in "${PYTEST_ARGS[@]}"; do
    if [ "$skip_next" -eq 1 ]; then USER_MARK="$arg"; skip_next=0; continue; fi
    case "$arg" in
        -m) skip_next=1 ;;
        -m=*|--markers=*) USER_MARK="${arg#*=}" ;;
        *) PHASE_ARGS+=("$arg") ;;
    esac
done

phase_mark() {
    if [ -n "$USER_MARK" ]; then echo "($USER_MARK) and $1"; else echo "$1"; fi
}

# A phase that matches no test exits 5 ("no tests collected"), which is normal
# here -- most invocations name a handful of tests and none of them are heavy --
# so it must not be reported as a failure.
run_phase() {
    local log="$1"; shift
    local phase_status=0
    set +e
    "$VENV/bin/python" -m pytest -s "$@" &> "$log"
    phase_status=$?
    set -e
    cat "$log"
    [ "$phase_status" -eq 5 ] && return 0
    return "$phase_status"
}

status=0
echo ">> Phase 1/2: parallel -- everything not in tests/smoke/heavy_tests.txt"
run_phase "$PARALLEL_LOG" -m "$(phase_mark 'not heavy')" "${PHASE_ARGS[@]}" || status=$?

# `-n 0` last so it beats the -n added above (and any the caller passed):
# pytest keeps the final value, and 0 is xdist's "run in this process". Using
# -p no:xdist instead would make the earlier -n an unrecognised argument.
echo ">> Phase 2/2: serial -- memory-heavy tests"
serial_status=0
run_phase "$SERIAL_LOG" -m "$(phase_mark 'heavy')" "${PHASE_ARGS[@]}" -n 0 || serial_status=$?
[ "$status" -eq 0 ] && status=$serial_status

# Collect this run's logs (per-test session logs, logs/failed/, and the qemu
# process logs) into .cache/qemu_smoke_logs/ — the local analogue of the remote
# runner's .cache/remote_smoke_logs/.
if [ -d "$SMOKE_DIR/logs" ]; then
    rm -rf "$QEMU_SMOKE_LOGS_DIR"
    mkdir -p "$QEMU_SMOKE_LOGS_DIR"
    cp -a "$SMOKE_DIR/logs/." "$QEMU_SMOKE_LOGS_DIR/"
    echo ">> Collected smoke logs in ${QEMU_SMOKE_LOGS_DIR#"$REPO_ROOT"/}"
    # Copied in only now, after the wipe above, so both phases' pytest output
    # ends up alongside the per-test logs it refers to.
    cp -f "$PARALLEL_LOG" "$SERIAL_LOG" "$QEMU_SMOKE_LOGS_DIR/" 2>/dev/null || true
    if [ -d "$QEMU_SMOKE_LOGS_DIR/failed" ]; then
        echo ">> Failed-test logs in ${QEMU_SMOKE_LOGS_DIR#"$REPO_ROOT"/}/failed"
    fi
fi

exit "$status"
