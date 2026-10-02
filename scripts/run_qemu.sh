#!/bin/sh
#
# run_qemu.sh — boot the yasos.zig kernel on QEMU's mps3-an524 (Cortex-M33),
# with the Zig compiler in the image.
#
# Usage: scripts/run_qemu.sh [options] [path/to/kernel.elf] [extra qemu args...]
#   --debug        Build the kernel Debug instead of ReleaseSafe (or set
#                  YASOS_QEMU_OPTIMIZE to any zig optimize mode).
#   --zig DIR      Build the Zig compiler from the Zig tree DIR into the image
#                  (build_rootfs.sh --zig). Default: $YASOS_ZIG_SOURCE, else a
#                  sibling ../zig-mem checkout when there is one.
#   --no-zig       Leave the Zig compiler out.
#   --an505        Boot the older mps2-an505 board. Its 5 MB romfs window
#                  cannot hold the Zig compiler, so this implies --no-zig.
#   --mount DIR    The host directory the guest sees at /mnt (default:
#                  $YASOS_QEMU_MNT, else .cache/qemu_mnt, created if missing).
#   --no-mount     No /mnt from the host.
#
#   /mnt: DIR is laid onto the board's 16 MB fatdisk before boot (.git and build
#   caches stay behind), and when QEMU exits whatever the guest added, changed
#   or deleted there is brought back into DIR -- point it at a git checkout and
#   `git diff` shows the guest's work. It is a three-way merge against what DIR
#   held at boot: a file edited on the PC meanwhile is never overwritten; the
#   guest's copy is kept beside it as <file>.target. Quit with Ctrl-A x only
#   after the guest's commands have finished writing. (scripts/qemu_mnt.py)
#
#   With NO ELF argument the script first (re)builds the userspace rootfs image
#   and then the kernel that embeds it, so the run always reflects the current
#   sources, before booting zig-out/bin/yasos_kernel.
#   Pass an explicit ELF path to skip the build and boot that image as-is.
#
#   The kernel is built -Doptimize=ReleaseSafe by default (matches the smoke
#   suite).
#
# To skip the rootfs/kernel rebuild set RUN_QEMU_SKIP_BUILD=1.
#
# The first build with Zig takes several minutes (a host Zig, zig.c, then the
# cross); apps/zig/build_zig.sh caches each step in .cache/zig-build, so later
# runs only redo what changed.
#
# Before building, the script selects the QEMU board defconfig so the produced
# kernel actually matches the machine below. Without this the build uses
# whatever board is currently configured (e.g. a real RP2350 / pimoroni board),
# and QEMU then faults at boot:
#   qemu: fatal: Lockup: can't escalate 3 to HardFault (current priority -1)
# Override the defconfig with QEMU_DEFCONFIG=... ; with RUN_QEMU_SKIP_BUILD=1
# no rebuild (and no reconfigure) happens and the existing ELF is booted as-is.
#
# UART0 is wired to stdio. Quit QEMU with Ctrl-A x.
#
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Default board: MPS3-AN524, as in scripts/run_qemu_smoke.sh. Its 2 GB DDR holds
# a romfs with the Zig compiler in it (~11 MB); the an505's 5 MB window does not.
# QEMU leaves the SSE-200 cores' FPU and DSP off by default; the kernel enables
# the FPU in crt_init and tcc emits DSP instructions (UMAAL), so both go on --
# see run_qemu_smoke.sh for the faults each one causes without it.
BOARD_DEFCONFIG="configs/qemu_mps3_an524_defconfig"
QEMU_MACHINE="mps3-an524"
QEMU_BOARD_ARGS="-global sse-200.CPU0_FPU=on -global sse-200.CPU1_FPU=on -global sse-200.CPU0_DSP=on -global sse-200.CPU1_DSP=on"

# Kernel build optimize mode. Defaults to ReleaseSafe so the QEMU run matches the
# smoke suite (scripts/run_qemu_smoke.sh); --debug selects Debug.
OPTIMIZE="${YASOS_QEMU_OPTIMIZE:-ReleaseSafe}"
ZIG_SOURCE="${YASOS_ZIG_SOURCE:-}"
MOUNT_DIR="${YASOS_QEMU_MNT:-$REPO_ROOT/.cache/qemu_mnt}"
WITH_ZIG=1
ZIG_ASKED=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug) OPTIMIZE="Debug"; shift ;;
        --zig)
            [ "$#" -ge 2 ] || { echo "error: --zig needs a Zig source directory" >&2; exit 1; }
            ZIG_SOURCE="$2"; WITH_ZIG=1; ZIG_ASKED=1; shift 2 ;;
        --no-zig) WITH_ZIG=0; shift ;;
        --mount)
            [ "$#" -ge 2 ] || { echo "error: --mount needs a directory" >&2; exit 1; }
            MOUNT_DIR="$2"; shift 2 ;;
        --no-mount) MOUNT_DIR=""; shift ;;
        --an505)
            BOARD_DEFCONFIG="configs/qemu_mps2_an505_defconfig"
            QEMU_MACHINE="mps2-an505"; QEMU_BOARD_ARGS=""; shift ;;
        *) break ;;
    esac
done
if [ "$QEMU_MACHINE" = "mps2-an505" ]; then
    if [ "$ZIG_ASKED" = "1" ] && [ "$WITH_ZIG" = "1" ]; then
        echo "error: --zig does not fit the an505's 5 MB romfs; drop --an505" >&2
        exit 1
    fi
    WITH_ZIG=0
fi
DEFCONFIG="${QEMU_DEFCONFIG:-$BOARD_DEFCONFIG}"

ELF=""
if [ "$#" -gt 0 ]; then
    ELF="$1"
    shift
fi

if [ -z "$ELF" ] && [ "${RUN_QEMU_SKIP_BUILD:-0}" != "1" ] && [ "$WITH_ZIG" = "1" ]; then
    if [ -z "$ZIG_SOURCE" ] && [ -f "$REPO_ROOT/../zig-mem/build.zig" ]; then
        ZIG_SOURCE="$REPO_ROOT/../zig-mem"
    fi
    if [ -z "$ZIG_SOURCE" ]; then
        echo "note: no Zig source tree (--zig DIR or YASOS_ZIG_SOURCE); building without the Zig compiler." >&2
    elif [ ! -f "$ZIG_SOURCE/build.zig" ]; then
        echo "error: $ZIG_SOURCE is not a Zig source tree (no build.zig)" >&2
        exit 1
    else
        ZIG_SOURCE=$(cd "$ZIG_SOURCE" && pwd)
    fi
else
    ZIG_SOURCE=""
fi

if [ -z "$ELF" ]; then
    if [ "${RUN_QEMU_SKIP_BUILD:-0}" = "1" ]; then
        echo "RUN_QEMU_SKIP_BUILD=1 set, skipping rootfs/kernel build."
    else
        # Select the QEMU board before anything is built, so the rootfs's kernel
        # rebuild and the `zig build` below both target the machine we boot. Skipping this
        # leaves a previously-configured board (e.g. pimoroni_pico_plus2) active
        # and QEMU locks up at boot.
        echo "==> Selecting QEMU board defconfig ($DEFCONFIG)..."
        ( cd "$REPO_ROOT" && zig build defconfig -Ddefconfig_file="$DEFCONFIG" )
        # Build userspace first: rootfs.img is embedded into the kernel ELF via
        # `.incbin "rootfs.img"`, so it has to exist (and be current) before the
        # kernel is built. --no-kernel skips build_rootfs's own kernel rebuild so
        # we don't build the kernel twice at conflicting optimize levels; the
        # `zig build -Doptimize=...` below re-embeds the fresh image at the level
        # we actually want. build_rootfs.sh aborts on any tool-build failure, and
        # `set -e` makes that abort us too, so we never boot a stale image.
        if [ -n "$ZIG_SOURCE" ]; then
            echo "==> Building rootfs image (build_rootfs.sh --no-kernel -o rootfs.img --zig $ZIG_SOURCE)..."
            ( cd "$REPO_ROOT" && ./build_rootfs.sh --no-kernel -o rootfs.img --zig "$ZIG_SOURCE" )
        else
            echo "==> Building rootfs image (build_rootfs.sh --no-kernel -o rootfs.img)..."
            ( cd "$REPO_ROOT" && ./build_rootfs.sh --no-kernel -o rootfs.img )
        fi
        echo "==> Building kernel (zig build -Doptimize=$OPTIMIZE)..."
        ( cd "$REPO_ROOT" && zig build -Doptimize="$OPTIMIZE" )
    fi
    ELF="$REPO_ROOT/zig-out/bin/yasos_kernel"
fi

if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF" >&2
    echo "build it with: zig build (after selecting the $DEFCONFIG defconfig)" >&2
    exit 1
fi

# The an505's fatdisk is a different window; only the an524 mounts DIR.
if [ "$QEMU_MACHINE" != "mps3-an524" ]; then
    MOUNT_DIR=""
fi

MEMORY_ARGS=""
if [ -n "$MOUNT_DIR" ]; then
    mkdir -p "$MOUNT_DIR"
    MOUNT_DIR=$(cd "$MOUNT_DIR" && pwd)
    RUN_DIR=$(mktemp -d "$REPO_ROOT/.cache/qemu_run.XXXXXX")
    trap 'rm -rf "$RUN_DIR"' EXIT
    BACKING="$RUN_DIR/mem.bin"
    STATE_DIR="$REPO_ROOT/.cache/qemu_mnt_state"
    mkdir -p "$STATE_DIR"
    STATE="$STATE_DIR/$(printf '%s' "$MOUNT_DIR" | sha1sum | cut -c1-16).json"
    python3 "$REPO_ROOT/scripts/qemu_mnt.py" seed "$MOUNT_DIR" "$BACKING" "$STATE"
    echo "==> $MOUNT_DIR is /mnt in the guest; changes come back when QEMU exits (Ctrl-A x)."
    # Guest RAM lives in a file so the fatdisk window is readable after exit.
    MEMORY_ARGS="-object memory-backend-file,id=mem0,size=2G,mem-path=$BACKING,share=on"
    QEMU_MACHINE="$QEMU_MACHINE,memory-backend=mem0"
fi

# Any remaining args ("$@") are forwarded to QEMU (e.g. -d int,guest_errors).
# $QEMU_BOARD_ARGS and $MEMORY_ARGS are unquoted on purpose: lists of words.
# shellcheck disable=SC2086
QEMU_RC=0
qemu-system-arm \
    -machine "$QEMU_MACHINE" \
    -cpu cortex-m33 \
    $QEMU_BOARD_ARGS \
    $MEMORY_ARGS \
    -nographic \
    -semihosting-config enable=on,target=native \
    -serial mon:stdio \
    -kernel "$ELF" \
    "$@" || QEMU_RC=$?

if [ -n "$MOUNT_DIR" ]; then
    echo "==> Bringing /mnt back into $MOUNT_DIR..."
    python3 "$REPO_ROOT/scripts/qemu_mnt.py" sync "$BACKING" "$MOUNT_DIR" "$STATE" || true
fi
exit "$QEMU_RC"
