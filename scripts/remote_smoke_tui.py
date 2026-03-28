#!/usr/bin/env python3

from __future__ import annotations

import argparse
import curses
import hashlib
import importlib.util
import json
import os
import shlex
import shutil
import queue
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
CACHE_PATH = REPO_ROOT / ".cache" / "remote_smoke_runner.json"
REMOTE_SMOKE_LOGS_DIR = REPO_ROOT / ".cache" / "remote_smoke_logs"
KERNEL_ARTIFACT = REPO_ROOT / "zig-out" / "bin" / "yasos_kernel"
ROOTFS_ARTIFACT = REPO_ROOT / "rootfs.img"
ROOTFS_HASH_PATH = REPO_ROOT / ".cache" / "rootfs_source_hash"
SMOKE_REQUIREMENTS = REPO_ROOT / "tests" / "smoke" / "requirements.txt"

# Directories and files whose content determines whether rootfs needs rebuilding.
_ROOTFS_SOURCE_DIRS = [
    "libs/libc",
    "libs/libdl",
    "libs/libm",
    "libs/pthread",
    "libs/yasos_curses",
    "libs/termcap",
    "libs/tinycc",
    "apps/coreutils",
    "apps/cowsay",
    "apps/ascii_animations",
    "apps/textvaders",
    "apps/hello_world",
    "apps/hexdump",
    "apps/yasvi",
    "apps/mkfs",
    "apps/longjump_tester",
    "apps/zork",
    "apps/rzsz",
    "apps/sha",
    "apps/toybox_builder",
]
_ROOTFS_SOURCE_FILES = [
    "build_rootfs.sh",
    "hello_world.c",
    "hello_script.sh",
]
_ROOTFS_SOURCE_EXTS = {".c", ".h", ".S", ".s", ".zig", ".sh", ".mk", ".ld"}


def _rootfs_sources_hash(debug: bool) -> str:
    """Compute a fast content hash over every source file that feeds into rootfs."""
    digest = hashlib.sha256()
    # Include the debug flag so Debug vs Release builds get different hashes.
    digest.update(b"debug" if debug else b"release")

    def _hash_file(path: Path) -> None:
        try:
            data = path.read_bytes()
        except OSError:
            return
        digest.update(str(path.relative_to(REPO_ROOT)).encode())
        digest.update(data)

    # Hash individual root-level files.
    for name in sorted(_ROOTFS_SOURCE_FILES):
        _hash_file(REPO_ROOT / name)

    # Hash source files inside tracked directories.
    for rel_dir in sorted(_ROOTFS_SOURCE_DIRS):
        d = REPO_ROOT / rel_dir
        if not d.is_dir():
            continue
        # Only hash Makefiles and files with known source extensions to
        # keep the fingerprint cheap and avoid hashing build artifacts.
        for p in sorted(d.rglob("*")):
            if p.is_dir() or "build" in p.parts:
                continue
            if p.suffix.lower() in _ROOTFS_SOURCE_EXTS or p.name in ("Makefile", "Makefile.inc", "configure", "configure.ac"):
                _hash_file(p)

    return digest.hexdigest()


def _rootfs_is_up_to_date(debug: bool) -> bool:
    """Return True when rootfs.img exists and no source inputs changed."""
    if not ROOTFS_ARTIFACT.exists():
        return False
    if not ROOTFS_HASH_PATH.exists():
        return False
    stored = ROOTFS_HASH_PATH.read_text().strip()
    current = _rootfs_sources_hash(debug)
    return stored == current


def _save_rootfs_hash(debug: bool) -> None:
    ROOTFS_HASH_PATH.parent.mkdir(parents=True, exist_ok=True)
    ROOTFS_HASH_PATH.write_text(_rootfs_sources_hash(debug) + "\n")


@dataclass(frozen=True)
class BoardProfile:
    key: str
    label: str
    defconfig: str
    interface_cfg: str
    target_cfg: str
    rootfs_address: str


BOARD_PROFILES = {
    "pimoroni_pico_plus2_and_vga": BoardProfile(
        key="pimoroni_pico_plus2_and_vga",
        label="Pimoroni Pico Plus 2 + VGA",
        defconfig="configs/pimoroni_pico_plus2_and_vga_defconfig",
        interface_cfg="interface/cmsis-dap.cfg",
        target_cfg="target/rp2350.cfg",
        rootfs_address="0x10100000",
    ),
    "mspc_v2": BoardProfile(
        key="mspc_v2",
        label="MSPC v2",
        defconfig="configs/mspc_defconfig",
        interface_cfg="interface/cmsis-dap.cfg",
        target_cfg="target/rp2350.cfg",
        rootfs_address="0x10100000",
    ),
}

OPTIMIZE_OPTIONS = ["ReleaseFast", "ReleaseSafe", "Debug", "ReleaseSmall"]

DEFAULT_CONFIG = {
    "board": "pimoroni_pico_plus2_and_vga",
    "ssh_target": "",
    "ssh_port": 22,
    "ssh_identity_file": "",
    "openocd_adapter_speed": 20000,
    "remote_repo_path": "",
    "remote_work_dir": "~/.cache/yasos-remote-smoke",
    "serial_device": "",
    "optimize": "ReleaseFast",
    "test_retries": 1,
    "with_gcc_torture": False,
    "pytest_args": "tests/smoke",
    "uhubctl_hub": "",
    "uhubctl_port": "",
}


class RunnerError(RuntimeError):
    pass


def effective_optimize(config: dict[str, Any], debug: bool) -> str:
    return "Debug" if debug else str(config["optimize"])


def merge_config(data: dict[str, Any] | None) -> dict[str, Any]:
    merged = dict(DEFAULT_CONFIG)
    if data:
        merged.update(data)
    if merged.get("board") not in BOARD_PROFILES:
        merged["board"] = DEFAULT_CONFIG["board"]
    if merged.get("optimize") not in OPTIMIZE_OPTIONS:
        merged["optimize"] = DEFAULT_CONFIG["optimize"]
    try:
        merged["ssh_port"] = int(merged.get("ssh_port", 22))
    except (TypeError, ValueError):
        merged["ssh_port"] = 22
    try:
        merged["openocd_adapter_speed"] = int(merged.get("openocd_adapter_speed", 20000))
    except (TypeError, ValueError):
        merged["openocd_adapter_speed"] = 20000
    try:
        merged["test_retries"] = int(merged.get("test_retries", 1))
    except (TypeError, ValueError):
        merged["test_retries"] = 1
    merged["with_gcc_torture"] = str(merged.get("with_gcc_torture", False)).strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    } if not isinstance(merged.get("with_gcc_torture"), bool) else bool(merged.get("with_gcc_torture"))
    merged.setdefault("uhubctl_hub", "")
    merged.setdefault("uhubctl_port", "")
    return merged


def load_cache() -> dict[str, Any]:
    if not CACHE_PATH.exists():
        return dict(DEFAULT_CONFIG)
    try:
        with CACHE_PATH.open("r", encoding="utf-8") as handle:
            return merge_config(json.load(handle))
    except json.JSONDecodeError as error:
        raise RunnerError(f"Cache file is not valid JSON: {CACHE_PATH} ({error})") from error


def save_cache(config: dict[str, Any]) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    with CACHE_PATH.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2, sort_keys=True)
        handle.write("\n")


def require(value: str, label: str) -> str:
    if not value.strip():
        raise RunnerError(f"{label} is required")
    return value.strip()


def normalize_ssh_auth_config(config: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(config)
    identity = str(normalized.get("ssh_identity_file", "")).strip()
    target = str(normalized.get("ssh_target", "")).strip()

    if not identity:
        return normalized

    identity_path = Path(identity).expanduser()
    looks_like_username = all(separator not in identity for separator in ("/", "\\")) and not identity.startswith((".", "~"))

    if looks_like_username and not identity_path.exists() and target and "@" not in target:
        normalized["ssh_target"] = f"{identity}@{target}"
        normalized["ssh_identity_file"] = ""

    return normalized


def validate_config(config: dict[str, Any]) -> dict[str, Any]:
    validated = normalize_ssh_auth_config(merge_config(config))
    require(validated["ssh_target"], "SSH target (user@host)")
    require(validated["remote_repo_path"], "Remote repository path")
    if validated["ssh_port"] <= 0:
        raise RunnerError("SSH port must be a positive integer")
    if validated["openocd_adapter_speed"] <= 0:
        raise RunnerError("OpenOCD adapter speed must be a positive integer in kHz")
    if validated["test_retries"] < 0:
        raise RunnerError("Test retries must be zero or greater")

    identity = str(validated["ssh_identity_file"]).strip()
    if identity:
        identity_path = Path(identity).expanduser()
        if not identity_path.exists():
            raise RunnerError(
                f"SSH identity file does not exist: {identity_path}. Leave SSH identity empty to use password or ssh-agent auth, and set SSH target to user@host."
            )

    board = BOARD_PROFILES[validated["board"]]
    defconfig_path = REPO_ROOT / board.defconfig
    if not defconfig_path.exists():
        raise RunnerError(f"Missing defconfig file: {defconfig_path}")

    return validated


def board_label(board_key: str) -> str:
    return BOARD_PROFILES[board_key].label


def board_key_from_label(label: str) -> str:
    for key, profile in BOARD_PROFILES.items():
        if profile.label == label:
            return key
    raise RunnerError(f"Unknown board label: {label}")


def cycle_option(options: list[str], current: str, direction: int) -> str:
    index = options.index(current)
    return options[(index + direction) % len(options)]


def edit_value(stdscr: curses.window, prompt: str, initial: str) -> str:
    height, width = stdscr.getmaxyx()
    window_width = min(max(len(prompt) + 12, 52), max(width - 4, 20))
    input_width = window_width - 4
    window = curses.newwin(5, window_width, max(0, height // 2 - 2), max(0, (width - window_width) // 2))
    window.keypad(True)
    window.border()
    window.addstr(1, 2, prompt[: input_width - 1])
    window.addstr(2, 2, initial[: input_width - 1])
    window.move(2, 2 + min(len(initial), input_width - 1))
    curses.curs_set(1)
    value = list(initial)
    cursor = len(value)
    while True:
        window.move(2, 2)
        display = "".join(value)[-input_width + 1 :]
        window.clrtoeol()
        window.addstr(2, 2, display)
        visible_cursor = min(cursor, input_width - 1)
        window.move(2, 2 + visible_cursor)
        key = window.getch()
        if key in (10, 13):
            curses.curs_set(0)
            return "".join(value)
        if key == 27:
            curses.curs_set(0)
            return initial
        if key in (curses.KEY_BACKSPACE, 127, 8):
            if cursor > 0:
                cursor -= 1
                value.pop(cursor)
            continue
        if key == curses.KEY_DC:
            if cursor < len(value):
                value.pop(cursor)
            continue
        if key == curses.KEY_LEFT:
            cursor = max(0, cursor - 1)
            continue
        if key == curses.KEY_RIGHT:
            cursor = min(len(value), cursor + 1)
            continue
        if 32 <= key <= 126:
            value.insert(cursor, chr(key))
            cursor += 1


def run_tui(initial_config: dict[str, Any]) -> dict[str, Any] | None:
    result: dict[str, Any] = {}

    def _inner(stdscr: curses.window) -> None:
        nonlocal result
        curses.curs_set(0)
        stdscr.keypad(True)
        config = dict(initial_config)
        status = "F5/r run, F2/s save, Enter edit, arrows move, q quit"
        fields = [
            ("Board", "board"),
            ("SSH target", "ssh_target"),
            ("SSH port", "ssh_port"),
            ("SSH identity", "ssh_identity_file"),
            ("OpenOCD speed", "openocd_adapter_speed"),
            ("Remote repo", "remote_repo_path"),
            ("Remote work dir", "remote_work_dir"),
            ("Serial device", "serial_device"),
            ("Optimize", "optimize"),
            ("Test retries", "test_retries"),
            ("With GCC torture", "with_gcc_torture"),
            ("Pytest args", "pytest_args"),
            ("uhubctl hub (auto)", "uhubctl_hub"),
            ("uhubctl port", "uhubctl_port"),
        ]
        selected = 0

        while True:
            stdscr.erase()
            height, width = stdscr.getmaxyx()
            stdscr.addstr(1, 2, "YasOS Remote Smoke Runner")
            stdscr.addstr(2, 2, f"Cache file: {CACHE_PATH.relative_to(REPO_ROOT)}")
            stdscr.addnstr(3, 2, "Use SSH target as user@host. Leave SSH identity empty unless you need a specific private key file.", width - 4)
            for index, (label, key) in enumerate(fields):
                row = 5 + index
                if row >= height - 3:
                    break
                display = config[key]
                if key == "board":
                    display = board_label(str(display))
                elif key == "with_gcc_torture":
                    display = "enabled" if bool(display) else "disabled"
                display = str(display)
                prefix = ">" if index == selected else " "
                line = f"{prefix} {label:<15} {display}"
                if index == selected:
                    stdscr.attron(curses.A_REVERSE)
                    stdscr.addnstr(row, 2, line, width - 4)
                    stdscr.attroff(curses.A_REVERSE)
                else:
                    stdscr.addnstr(row, 2, line, width - 4)
            stdscr.addnstr(height - 2, 2, status, width - 4)
            stdscr.refresh()

            key = stdscr.getch()
            if key in (ord("q"), ord("Q")):
                result = None
                return
            if key == curses.KEY_UP:
                selected = (selected - 1) % len(fields)
                continue
            if key == curses.KEY_DOWN:
                selected = (selected + 1) % len(fields)
                continue
            if key == curses.KEY_LEFT:
                selected_key = fields[selected][1]
                if selected_key == "board":
                    config[selected_key] = board_key_from_label(
                        cycle_option([profile.label for profile in BOARD_PROFILES.values()], board_label(str(config[selected_key])), -1)
                    )
                elif selected_key == "optimize":
                    config[selected_key] = cycle_option(OPTIMIZE_OPTIONS, str(config[selected_key]), -1)
                elif selected_key == "with_gcc_torture":
                    config[selected_key] = not bool(config[selected_key])
                continue
            if key == curses.KEY_RIGHT:
                selected_key = fields[selected][1]
                if selected_key == "board":
                    config[selected_key] = board_key_from_label(
                        cycle_option([profile.label for profile in BOARD_PROFILES.values()], board_label(str(config[selected_key])), 1)
                    )
                elif selected_key == "optimize":
                    config[selected_key] = cycle_option(OPTIMIZE_OPTIONS, str(config[selected_key]), 1)
                elif selected_key == "with_gcc_torture":
                    config[selected_key] = not bool(config[selected_key])
                continue
            if key in (curses.KEY_F2, ord("s"), ord("S")):
                try:
                    validated = validate_config(config)
                    save_cache(validated)
                    status = f"Saved {CACHE_PATH.relative_to(REPO_ROOT)}"
                except RunnerError as error:
                    status = str(error)
                continue
            if key in (curses.KEY_F5, ord("r"), ord("R")):
                try:
                    result = validate_config(config)
                    save_cache(result)
                    return
                except RunnerError as error:
                    status = str(error)
                continue
            if key in (10, 13):
                label, selected_key = fields[selected]
                if selected_key == "board":
                    config[selected_key] = board_key_from_label(
                        cycle_option([profile.label for profile in BOARD_PROFILES.values()], board_label(str(config[selected_key])), 1)
                    )
                    continue
                if selected_key == "optimize":
                    config[selected_key] = cycle_option(OPTIMIZE_OPTIONS, str(config[selected_key]), 1)
                    continue
                if selected_key == "with_gcc_torture":
                    config[selected_key] = not bool(config[selected_key])
                    continue
                edited = edit_value(stdscr, label, str(config[selected_key]))
                if selected_key in ("ssh_port", "openocd_adapter_speed", "test_retries"):
                    if selected_key == "ssh_port":
                        default_value = "22"
                    elif selected_key == "openocd_adapter_speed":
                        default_value = "20000"
                    else:
                        default_value = "1"
                    config[selected_key] = edited.strip() or default_value
                else:
                    config[selected_key] = edited

    curses.wrapper(_inner)
    return result


def command_string(cmd: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in cmd)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_command(cmd: list[str], cwd: Path | None = None, input_text: str | None = None) -> None:
    print(f"\n$ {command_string(cmd)}")
    completed = subprocess.run(
        cmd,
        cwd=cwd,
        input=input_text,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RunnerError(f"Command failed with exit code {completed.returncode}: {command_string(cmd)}")


def run_interactive_command(cmd: list[str], cwd: Path | None = None, input_text: str | None = None) -> None:
    print(f"\n$ {command_string(cmd)}")
    completed = subprocess.run(
        cmd,
        cwd=cwd,
        input=input_text,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RunnerError(f"Interactive command failed with exit code {completed.returncode}: {command_string(cmd)}")


def capture_command(cmd: list[str], cwd: Path | None = None, input_text: str | None = None) -> str:
    print(f"\n$ {command_string(cmd)}")
    completed = subprocess.run(
        cmd,
        cwd=cwd,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise RunnerError(f"Command failed with exit code {completed.returncode}: {command_string(cmd)}")
    lines = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    if not lines:
        raise RunnerError(f"Command produced no output: {command_string(cmd)}")
    return lines[-1]


def detect_remote_debug_tools(config: dict[str, Any]) -> str:
    remote_script = """set -euo pipefail

if ! command -v openocd >/dev/null 2>&1; then
    echo "missing: openocd" >&2
    exit 1
fi

if ! command -v uhubctl >/dev/null 2>&1; then
    echo "warning: uhubctl not found, USB power-cycle reset unavailable" >&2
fi

for candidate in arm-none-eabi-gdb gdb-multiarch gdb; do
    if command -v "$candidate" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

echo "missing: gdb" >&2
exit 1
"""
    return capture_command(ssh_base(config) + ["bash", "-s"], input_text=remote_script)


def require_local_rsync() -> None:
    if shutil.which("rsync") is None:
        raise RunnerError("Local rsync is required for remote debug artifact sync")


def verify_remote_rsync(config: dict[str, Any]) -> None:
    remote_script = """set -euo pipefail
remote_repo=$1

if ! command -v rsync >/dev/null 2>&1; then
    echo "missing: rsync" >&2
    exit 1
fi

cd "$remote_repo"
"""
    run_command(
        ssh_base(config) + ["bash", "-s", "--", str(config["remote_repo_path"])],
        input_text=remote_script,
    )


def load_yasld_elf_map() -> dict[str, str]:
    module_path = REPO_ROOT / "scripts" / "yasld_gdb.py"
    spec = importlib.util.spec_from_file_location("yasld_gdb", module_path)
    if spec is None or spec.loader is None:
        raise RunnerError(f"Unable to load ELF map from {module_path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    elf_map = getattr(module, "ELF_MAP", None)
    if not isinstance(elf_map, dict):
        raise RunnerError(f"ELF_MAP is missing or invalid in {module_path}")

    return {str(name): str(path) for name, path in elf_map.items()}


def debug_sync_paths() -> list[str]:
    paths = ["scripts/yasld_gdb.py", KERNEL_ARTIFACT.relative_to(REPO_ROOT).as_posix()]
    # Include any GDB script files (e.g. gdb_debug_plan.gdb)
    for gdb_file in (REPO_ROOT / "libs" / "tinycc").glob("*.gdb"):
        paths.append(gdb_file.relative_to(REPO_ROOT).as_posix())
    for rel_path in load_yasld_elf_map().values():
        candidate = REPO_ROOT / rel_path
        if candidate.exists():
            paths.append(rel_path)
    return sorted(set(paths))


def sync_remote_repo_subset(config: dict[str, Any], rel_paths: list[str]) -> str:
    require_local_rsync()
    verify_remote_rsync(config)

    remote_repo = str(config["remote_repo_path"]).rstrip("/") + "/"
    remote_dest = f"{config['ssh_target']}:{remote_repo}"
    ssh_cmd = ssh_transport_base(config)
    rsync_cmd = [
        "rsync",
        "-az",
        "--info=progress2",
        "--files-from=-",
        "-e",
        command_string(ssh_cmd),
        "./",
        remote_dest,
    ]
    print(f"Syncing {len(rel_paths)} files to remote...")
    run_command(rsync_cmd, cwd=REPO_ROOT, input_text="\n".join(rel_paths) + "\n")
    return remote_repo.rstrip("/")


def sync_remote_repo_sources(config: dict[str, Any]) -> str:
    require_local_rsync()
    verify_remote_rsync(config)

    remote_repo = str(config["remote_repo_path"]).rstrip("/") + "/"
    remote_dest = f"{config['ssh_target']}:{remote_repo}"
    ssh_cmd = ssh_transport_base(config)
    rsync_cmd = [
        "rsync",
        "-az",
        "--info=progress2",
        "--delete",
        "--exclude=.git/",
        "--exclude=.cache/",
        "--exclude=zig-cache/",
        "--exclude=zig-out/",
        "--exclude=yasos_venv/",
        "--exclude=__pycache__/",
        "--exclude=*.pyc",
        "--exclude=.DS_Store",
        "-e",
        command_string(ssh_cmd),
        "./",
        remote_dest,
    ]
    print("Syncing repository sources to remote...")
    run_command(rsync_cmd, cwd=REPO_ROOT)
    return remote_repo.rstrip("/")


def sync_debug_artifacts(config: dict[str, Any]) -> str:
    rel_paths = debug_sync_paths()
    remote_repo = sync_remote_repo_subset(config, rel_paths)
    return f"{remote_repo.rstrip('/')}/{KERNEL_ARTIFACT.relative_to(REPO_ROOT).as_posix()}"


def select_remote_gdb_kernel(config: dict[str, Any], fallback_remote_kernel: str) -> tuple[str, bool]:
    remote_work_dir = prepare_remote_work_dir(config)
    flashed_remote_kernel = f"{remote_work_dir.rstrip('/')}/yasos_kernel"
    remote_script = """set -euo pipefail
flashed_remote_kernel=$1
fallback_remote_kernel=$2

if [[ -f "$flashed_remote_kernel" ]]; then
    printf '%s\n' "$flashed_remote_kernel"
else
    printf '%s\n' "$fallback_remote_kernel"
fi
"""
    selected_kernel = capture_command(
        ssh_base(config) + ["bash", "-s", "--", flashed_remote_kernel, fallback_remote_kernel],
        input_text=remote_script,
    )
    return selected_kernel, selected_kernel == flashed_remote_kernel


def smoke_sync_paths(config: dict[str, Any]) -> list[str]:
    paths: set[str] = set()

    def add_path(rel_path: str) -> None:
        rel_path = rel_path.split("::", 1)[0]
        candidate = REPO_ROOT / rel_path
        if not candidate.exists():
            return
        if candidate.is_dir():
            for file_path in candidate.rglob("*"):
                if file_path.is_file():
                    paths.add(file_path.relative_to(REPO_ROOT).as_posix())
            return
        paths.add(candidate.relative_to(REPO_ROOT).as_posix())

    add_path("tests/smoke")
    add_path("libs/tinycc/tests/tests2")
    add_path("libs/tinycc/tests/ir_tests")
    if bool(config.get("with_gcc_torture", False)):
        add_path("libs/tinycc/tests/gcctestsuite")
    pytest_args = shlex.split(str(config["pytest_args"]).strip() or "tests/smoke")
    for arg in pytest_args:
        if arg.startswith("-"):
            continue
        add_path(arg)
    return sorted(paths)


def sync_smoke_support(config: dict[str, Any]) -> None:
    sync_remote_repo_sources(config)
    sync_remote_repo_subset(config, smoke_sync_paths(config))


def ssh_base(config: dict[str, Any]) -> list[str]:
    command = ssh_transport_base(config)
    command.append(str(config["ssh_target"]))
    return command


def ssh_transport_base(config: dict[str, Any]) -> list[str]:
    command = ["ssh", "-p", str(config["ssh_port"])]
    identity = str(config["ssh_identity_file"]).strip()
    if identity:
        command.extend(["-i", identity])
    return command


def ssh_tty_base(config: dict[str, Any]) -> list[str]:
    command = ["ssh", "-t", "-p", str(config["ssh_port"])]
    identity = str(config["ssh_identity_file"]).strip()
    if identity:
        command.extend(["-i", identity])
    command.append(str(config["ssh_target"]))
    return command


def run_remote_tty_script(config: dict[str, Any], script: str) -> None:
    cmd = ssh_tty_base(config) + ["bash", "-lc", script]
    run_interactive_command(cmd)


def scp_base(config: dict[str, Any]) -> list[str]:
    command = ["scp", "-P", str(config["ssh_port"])]
    identity = str(config["ssh_identity_file"]).strip()
    if identity:
        command.extend(["-i", identity])
    return command


def safe_path_component(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "_" for ch in value)


def remote_directory_exists(config: dict[str, Any], remote_path: str) -> bool:
    remote_script = """set -euo pipefail
remote_path=$1

[[ -d "$remote_path" ]]
"""
    completed = subprocess.run(
        ssh_base(config) + ["bash", "-s", "--", remote_path],
        input=remote_script,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return completed.returncode == 0


def fetch_remote_smoke_logs(config: dict[str, Any]) -> Path | None:
    remote_repo = str(config["remote_repo_path"]).rstrip("/")
    remote_logs_dir = f"{remote_repo}/logs"
    local_logs_dir = REMOTE_SMOKE_LOGS_DIR / safe_path_component(str(config["ssh_target"]))

    if local_logs_dir.exists():
        shutil.rmtree(local_logs_dir)

    if not remote_directory_exists(config, remote_logs_dir):
        return None

    require_local_rsync()
    verify_remote_rsync(config)

    local_logs_dir.mkdir(parents=True, exist_ok=True)

    rsync_cmd = [
        "rsync",
        "-az",
        "-e",
        command_string(ssh_transport_base(config)),
        f"{config['ssh_target']}:{remote_logs_dir.rstrip('/')}/",
        str(local_logs_dir) + "/",
    ]
    run_command(rsync_cmd, cwd=REPO_ROOT)
    return local_logs_dir


def _quiet_log_sync(config: dict[str, Any]) -> int:
    """Rsync remote logs to local without printing commands. Returns count of new files."""
    remote_repo = str(config["remote_repo_path"]).rstrip("/")
    remote_logs_dir = f"{remote_repo}/logs"
    local_logs_dir = REMOTE_SMOKE_LOGS_DIR / safe_path_component(str(config["ssh_target"]))
    local_logs_dir.mkdir(parents=True, exist_ok=True)

    before = set(local_logs_dir.rglob("*")) if local_logs_dir.exists() else set()

    rsync_cmd = [
        "rsync",
        "-az",
        "-e",
        command_string(ssh_transport_base(config)),
        f"{config['ssh_target']}:{remote_logs_dir.rstrip('/')}/",
        str(local_logs_dir) + "/",
    ]
    completed = subprocess.run(
        rsync_cmd,
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        return 0

    after = set(local_logs_dir.rglob("*"))
    return len(after - before)


def _background_log_sync(
    config: dict[str, Any],
    stop_event: threading.Event,
    msg_queue: queue.Queue[str],
    interval: float = 10.0,
) -> None:
    """Periodically sync remote logs in a background thread, buffering messages."""
    while not stop_event.is_set():
        stop_event.wait(interval)
        if stop_event.is_set():
            break
        try:
            new_files = _quiet_log_sync(config)
            if new_files > 0:
                local_logs_dir = REMOTE_SMOKE_LOGS_DIR / safe_path_component(str(config["ssh_target"]))
                total = sum(1 for _ in local_logs_dir.rglob("*.txt")) if local_logs_dir.exists() else 0
                msg_queue.put(f"[log sync] {new_files} new log(s) fetched ({total} total in {local_logs_dir})")
        except Exception:
            pass


def _drain_sync_messages(msg_queue: queue.Queue[str]) -> None:
    """Print all pending log-sync messages."""
    while True:
        try:
            msg = msg_queue.get_nowait()
        except queue.Empty:
            break
        print(msg, flush=True)


def prepare_remote_work_dir(config: dict[str, Any]) -> str:
    requested = str(config["remote_work_dir"]).strip()
    if not requested:
        raise RunnerError("Remote work dir is required")
    remote_script = """set -euo pipefail
path=$1

if [[ $path == "~" ]]; then
  path="$HOME"
elif [[ $path == ~/* ]]; then
  path="$HOME/${path#~/}"
fi

mkdir -p "$path"
printf '%s\n' "$path"
"""
    return capture_command(
        ssh_base(config) + ["bash", "-s", "--", requested],
        input_text=remote_script,
    )


def prepare_remote_repo_path(config: dict[str, Any]) -> str:
        requested = str(config["remote_repo_path"]).strip()
        if not requested:
                raise RunnerError("Remote repository path is required")
        remote_script = """set -euo pipefail
path=$1

if [[ $path == "~" ]]; then
    path="$HOME"
elif [[ $path == ~/* ]]; then
    path="$HOME/${path#~/}"
fi

mkdir -p "$path"

printf '%s\n' "$path"
"""
        return capture_command(
                ssh_base(config) + ["bash", "-s", "--", requested],
                input_text=remote_script,
        )


def _set_kconfig_option(option: str, value: str = "y") -> bool:
    """Enable a Kconfig option in .config and regenerate config files.

    Returns True if the config was changed, False if already set.
    """
    config_path = REPO_ROOT / "config" / "target" / ".config"
    if not config_path.exists():
        return False

    text = config_path.read_text()
    enabled_line = f"{option}={value}"
    disabled_line = f"# {option} is not set"

    if enabled_line in text:
        return False

    if disabled_line in text:
        new_text = text.replace(disabled_line, enabled_line)
    elif option not in text:
        new_text = text.rstrip("\n") + "\n" + enabled_line + "\n"
    else:
        return False

    config_path.write_text(new_text)
    run_command(
        [
            "./yasos_venv/bin/python",
            "./kconfiglib/generate.py",
            "--input", str(config_path),
            "-k", "Kconfig",
            "-o", "config/target",
        ],
        cwd=REPO_ROOT,
    )
    return True


def build_local_artifacts(
    config: dict[str, Any],
    debug: bool = False,
    build_rootfs: bool = True,
    force: bool = False,
    apply_defconfig: bool = False,
) -> None:
    if apply_defconfig:
        board = BOARD_PROFILES[config["board"]]
        run_command(
            [
                "zig",
                "build",
                "defconfig",
                f"-Ddefconfig_file={board.defconfig}",
            ],
            cwd=REPO_ROOT,
        )
    if config.get("profile"):
        if _set_kconfig_option("CONFIG_INSTRUMENTATION_PERF_PROFILING"):
            print("Enabled CONFIG_INSTRUMENTATION_PERF_PROFILING for profiling.")
    run_command(
        ["zig", "build", f"-Doptimize={effective_optimize(config, debug)}"],
        cwd=REPO_ROOT,
    )
    rootfs_cmd = ["./build_rootfs.sh", "-o", ROOTFS_ARTIFACT.name]
    if build_rootfs:
        if force:
            rootfs_cmd.insert(1, "-c")
            if debug:
                rootfs_cmd.append("--debug")
            run_command(rootfs_cmd, cwd=REPO_ROOT)
            _save_rootfs_hash(debug)
        elif _rootfs_is_up_to_date(debug):
            print("rootfs sources unchanged — skipping build_rootfs.sh")
        else:
            if debug:
                rootfs_cmd.append("--debug")
            run_command(rootfs_cmd, cwd=REPO_ROOT)
            _save_rootfs_hash(debug)

    if not KERNEL_ARTIFACT.exists():
        raise RunnerError(f"Expected kernel artifact was not produced: {KERNEL_ARTIFACT}")
    if build_rootfs and not ROOTFS_ARTIFACT.exists():
        raise RunnerError(f"Expected rootfs image was not produced: {ROOTFS_ARTIFACT}")


def upload_kernel_artifact(config: dict[str, Any]) -> tuple[str, str]:
    remote_work_dir = prepare_remote_work_dir(config)
    remote_kernel = f"{remote_work_dir.rstrip('/')}/yasos_kernel"
    run_command(
        scp_base(config)
        + [
            str(KERNEL_ARTIFACT),
            f"{config['ssh_target']}:{remote_kernel}",
        ]
    )
    return remote_work_dir, remote_kernel


def upload_artifacts(config: dict[str, Any]) -> tuple[str, str, str]:
    remote_work_dir = prepare_remote_work_dir(config)
    remote_kernel = f"{remote_work_dir.rstrip('/')}/yasos_kernel"
    remote_rootfs = f"{remote_work_dir.rstrip('/')}/rootfs.img"
    run_command(
        scp_base(config)
        + [
            str(KERNEL_ARTIFACT),
            str(ROOTFS_ARTIFACT),
            f"{config['ssh_target']}:{remote_work_dir}/",
        ]
    )
    return remote_work_dir, remote_kernel, remote_rootfs


def run_remote_smoke(
    config: dict[str, Any],
    remote_work_dir: str,
    remote_kernel: str,
    remote_rootfs: str,
    flash_only: bool,
    kernel_sha: str,
    rootfs_sha: str,
    requirements_sha: str,
    force: bool,
    kernel_only: bool = False,
) -> None:
    board = BOARD_PROFILES[config["board"]]
    adapter_speed = str(config["openocd_adapter_speed"])
    test_retries = int(config.get("test_retries", 0))
    pytest_args = shlex.split(str(config["pytest_args"]).strip() or "tests/smoke")
    remote_script = """set -euo pipefail
remote_repo=$1
remote_work_dir=$2
interface_cfg=$3
target_cfg=$4
adapter_speed=$5
rootfs_address=$6
serial_device=$7
remote_kernel=$8
remote_rootfs=$9
flash_only=${10}
test_retries=${11}
with_gcc_torture=${12}
kernel_sha=${13}
rootfs_sha=${14}
requirements_sha=${15}
force=${16}
profile=${17}
uhubctl_hub=${18}
uhubctl_port=${19}
kernel_only=${20}
extra_tcc_cflags=${21}
shift 21

detect_uhubctl_device() {
    # Find a USB device by vendor ID in sysfs and return its hub location
    # and port for uhubctl.  Prints "hub_path port" on stdout.
    local vid=${1:-2e8a}
    for dev in /sys/bus/usb/devices/*/; do
        [[ -f "$dev/idVendor" ]] || continue
        local v
        v=$(cat "$dev/idVendor" 2>/dev/null) || continue
        if [[ "$v" == "$vid" ]]; then
            local devname
            devname=$(basename "$dev")
            # devname is e.g. "3-1.2" → parent hub "3-1", port "2"
            #            or   "3-1"   → root hub bus "3", port "1"
            if [[ "$devname" == *.* ]]; then
                echo "${devname%.*} ${devname##*.}"
            else
                local bus="${devname%%-*}"
                local port="${devname#*-}"
                echo "$bus $port"
            fi
            return 0
        fi
    done
    return 1
}

resolve_uhubctl() {
    # Resolve uhubctl_hub / uhubctl_port.  When hub is "auto", detect from
    # the debug probe's sysfs entry.  When port is empty, cycle the whole hub.
    # If the detected hub is not uhubctl-compatible, walk up to the root hub.
    if [[ "$uhubctl_hub" == "auto" ]]; then
        local detected
        if detected=$(detect_uhubctl_device 2e8a); then
            uhubctl_hub="${detected%% *}"
            if [[ -z "$uhubctl_port" ]]; then
                uhubctl_port="${detected##* }"
            fi
            # Verify uhubctl recognises this hub; walk up if not.
            if ! uhubctl_cmd -l "$uhubctl_hub" >/dev/null 2>&1; then
                echo "Hub $uhubctl_hub not uhubctl-compatible, walking up to parent..." >&2
                if [[ "$uhubctl_hub" == *.* ]]; then
                    # e.g. "3-1.2" → parent "3-1", port "2"
                    uhubctl_port="${uhubctl_hub##*.}"
                    uhubctl_hub="${uhubctl_hub%.*}"
                else
                    # e.g. "3-1" → root hub bus "3", port "1"
                    uhubctl_port="${uhubctl_hub#*-}"
                    uhubctl_hub="${uhubctl_hub%%-*}"
                fi
            fi
            echo "Auto-detected uhubctl: hub=$uhubctl_hub port=$uhubctl_port" >&2
        else
            echo "WARNING: could not auto-detect USB hub for Pico debug probe" >&2
            uhubctl_hub=""
            uhubctl_port=""
        fi
    fi
}

resolve_uhubctl

uhubctl_cmd() {
    # uhubctl lives in /usr/sbin and needs root
    local bin
    bin=$(command -v uhubctl 2>/dev/null || echo /usr/sbin/uhubctl)
    if [[ -x "$bin" ]]; then
        sudo "$bin" "$@"
    else
        return 1
    fi
}

usb_power_reset() {
    if [[ -n "$uhubctl_hub" ]] && uhubctl_cmd --version >/dev/null 2>&1; then
        local port_args=()
        if [[ -n "$uhubctl_port" ]]; then
            port_args=(-p "$uhubctl_port")
        fi
        echo "Power-cycling USB (hub=$uhubctl_hub port=${uhubctl_port:-all})..." >&2
        uhubctl_cmd -l "$uhubctl_hub" "${port_args[@]}" -a off -r 100 2>/dev/null || true
        sleep 3
        # After power-off the hub disappears from the bus; uhubctl may
        # segfault when trying to re-scan.  Retry the 'on' command.
        for _attempt in 1 2 3; do
            if uhubctl_cmd -l "$uhubctl_hub" "${port_args[@]}" -a on -r 100 2>/dev/null; then
                break
            fi
            sleep 2
        done
        sleep 3
        # Wait for the debug probe to re-enumerate on the bus.
        echo "Waiting for debug probe to re-enumerate..." >&2
        for _wait in $(seq 1 15); do
            if ls /dev/ttyACM* >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        sleep 1
        return 0
    fi
    return 1
}

openocd_reset_halt() {
    # Catch the CPU before it runs bad firmware after a power cycle.
    # Try normal reset halt first; if that fails, use rescue DP.
    if openocd -f "$interface_cfg" -f "$target_cfg" \
        -c "adapter speed $adapter_speed" \
        -c "init" -c "reset halt" -c "exit" 2>/dev/null; then
        return 0
    fi
    echo "reset halt failed, trying rescue DP..." >&2
    openocd_rescue_reset
}

openocd_rescue_reset() {
    # Use the RP2350 rescue debug port to force-halt the chip.
    # This works even when the CPU is stuck running bad firmware.
    local rescue_cfg="target/rp2350-rescue.cfg"
    if ! openocd -f "$interface_cfg" -f "$rescue_cfg" \
        -c "adapter speed 5000" -c "init" -c "exit" 2>&1; then
        echo "rescue DP reset failed" >&2
        return 1
    fi
    # After rescue, the chip is halted. Give it a moment.
    sleep 1
    return 0
}

mkdir -p "$remote_work_dir"

artifact_state_dir="$remote_work_dir/.artifact-state"
kernel_sha_file="$artifact_state_dir/kernel.sha256"
rootfs_sha_file="$artifact_state_dir/rootfs.sha256"
mkdir -p "$artifact_state_dir"

flash_kernel=1
flash_rootfs=1

if [[ "$kernel_only" == "1" ]]; then
    flash_rootfs=0
fi

if [[ "$force" != "1" ]]; then
    if [[ -f "$kernel_sha_file" ]] && [[ "$(cat "$kernel_sha_file")" == "$kernel_sha" ]]; then
        flash_kernel=0
    fi
    if (( flash_rootfs )) && [[ -f "$rootfs_sha_file" ]] && [[ "$(cat "$rootfs_sha_file")" == "$rootfs_sha" ]]; then
        flash_rootfs=0
    fi
fi

if (( flash_kernel || flash_rootfs )); then
    # Rescue DP reset first to clear any QSPI Quad I/O mode left by
    # overclock firmware — avoids CRC checksum mismatches during verify.
    openocd_rescue_reset 2>/dev/null || true

    openocd_cmd=(
        openocd
        -f "$interface_cfg"
        -f "$target_cfg"
        -c "adapter speed $adapter_speed"
        -c "init"
        -c "reset halt"
    )
    if (( flash_rootfs )); then
        openocd_cmd+=( -c "program $remote_rootfs $rootfs_address" )
    fi
    if (( flash_kernel )); then
        openocd_cmd+=( -c "program $remote_kernel verify" )
    fi
    openocd_cmd+=( -c "reset run" -c "exit" )

    flash_ok=0
    for flash_attempt in 1 2 3; do
        if "${openocd_cmd[@]}"; then
            flash_ok=1
            break
        fi
        echo "Flash attempt $flash_attempt failed, resetting target and retrying..." >&2
        if (( flash_attempt == 1 )); then
            # First retry: rescue DP clears double-fault lockups quickly
            echo "Trying rescue DP reset..." >&2
            openocd_rescue_reset
        elif (( flash_attempt == 2 )); then
            # Last retry: full USB power-cycle to recover from any state
            if usb_power_reset; then
                echo "USB power-cycle complete, halting target..." >&2
                openocd_reset_halt || openocd_rescue_reset
            else
                sleep 2
                openocd_rescue_reset
            fi
        fi
    done
    if (( ! flash_ok )); then
        echo "ERROR: flashing failed after 3 attempts" >&2
        exit 1
    fi

    if (( flash_kernel )); then
        printf '%s\n' "$kernel_sha" > "$kernel_sha_file"
    fi
    if (( flash_rootfs )); then
        printf '%s\n' "$rootfs_sha" > "$rootfs_sha_file"
    fi
else
    echo "Artifacts unchanged; skipping flash and resetting target only."
    openocd_rescue_reset 2>/dev/null || true

    openocd_cmd=(
        openocd
        -f "$interface_cfg"
        -f "$target_cfg"
        -c "adapter speed $adapter_speed"
        -c "init"
        -c "reset halt"
        -c "reset run"
        -c "exit"
    )

    reset_ok=0
    for reset_attempt in 1 2 3; do
        if "${openocd_cmd[@]}"; then
            reset_ok=1
            break
        fi
        echo "Reset attempt $reset_attempt failed, retrying..." >&2
        if (( reset_attempt == 1 )); then
            echo "Trying rescue DP reset..." >&2
            openocd_rescue_reset
        elif (( reset_attempt == 2 )); then
            if usb_power_reset; then
                echo "USB power-cycle complete, halting target..." >&2
                openocd_reset_halt || openocd_rescue_reset
            else
                sleep 2
                openocd_rescue_reset
            fi
        fi
    done
    if (( ! reset_ok )); then
        echo "ERROR: target reset failed after 3 attempts" >&2
        exit 1
    fi
fi

if [[ "$flash_only" == "1" ]]; then
    exit 0
fi

cd "$remote_repo"
rm -rf "$remote_repo/logs"
mkdir -p "$remote_repo/logs"
export YASOS_TIMING_REPORT_DIR="$remote_repo/logs"

if [[ ! -x "$remote_work_dir/venv/bin/python3" ]]; then
    python3 -m venv "$remote_work_dir/venv"
fi

requirements_sha_file="$remote_work_dir/venv/.requirements.sha256"
if [[ "$force" == "1" ]] || [[ ! -f "$requirements_sha_file" ]] || [[ "$(cat "$requirements_sha_file")" != "$requirements_sha" ]]; then
    "$remote_work_dir/venv/bin/pip" install -r "$remote_repo/tests/smoke/requirements.txt"
    printf '%s\n' "$requirements_sha" > "$requirements_sha_file"
else
    echo "Smoke venv unchanged; skipping pip install."
fi

if [[ -n "$serial_device" ]]; then
  export SERIAL_DEVICE="$serial_device"
fi

if [[ "${with_gcc_torture}" == "1" ]]; then
    export YASOS_SMOKE_ENABLE_GCC_TORTURE=1
fi

if [[ "${profile}" == "1" ]]; then
    export YASOS_TCC_PROFILE=1
fi

if [[ -n "${extra_tcc_cflags}" ]]; then
    export YASOS_EXTRA_TCC_CFLAGS="${extra_tcc_cflags}"
fi

pytest_cmd=("$remote_work_dir/venv/bin/pytest" -W error -sv)
if (( test_retries > 0 )); then
    pytest_cmd+=(--reruns "$test_retries" --reruns-delay 1)
fi

"${pytest_cmd[@]}" "$@"
"""
    # SSH concatenates remote command args with spaces before sending to the
    # remote shell.  Empty strings and values with special characters would be
    # lost or mis-parsed without proper quoting.
    remote_args = [
        str(config["remote_repo_path"]),
        remote_work_dir,
        board.interface_cfg,
        board.target_cfg,
        adapter_speed,
        board.rootfs_address,
        str(config["serial_device"]),
        remote_kernel,
        remote_rootfs,
        "1" if flash_only else "0",
        str(test_retries),
        "1" if bool(config.get("with_gcc_torture", False)) else "0",
        kernel_sha,
        rootfs_sha,
        requirements_sha,
        "1" if force else "0",
        "1" if bool(config.get("profile", False)) else "0",
        str(config.get("uhubctl_hub", "")),
        str(config.get("uhubctl_port", "")),
        "1" if kernel_only else "0",
        str(config.get("extra_tcc_cflags", "")),
        *pytest_args,
    ]
    cmd = ssh_base(config) + [
        "bash", "-s", "--",
        *[shlex.quote(a) for a in remote_args],
    ]
    run_error: RunnerError | None = None
    stop_sync = threading.Event()
    sync_queue: queue.Queue[str] = queue.Queue()
    sync_thread: threading.Thread | None = None
    if not flash_only:
        local_logs_dir = REMOTE_SMOKE_LOGS_DIR / safe_path_component(str(config["ssh_target"]))
        if local_logs_dir.exists():
            shutil.rmtree(local_logs_dir)
        sync_thread = threading.Thread(
            target=_background_log_sync,
            args=(config, stop_sync, sync_queue),
            daemon=True,
        )
        sync_thread.start()
    try:
        print(f"\n$ {command_string(cmd)}")
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if remote_script is not None:
            proc.stdin.write(remote_script)
            proc.stdin.close()
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            _drain_sync_messages(sync_queue)
        proc.wait()
        _drain_sync_messages(sync_queue)
        if proc.returncode != 0:
            raise RunnerError(f"Command failed with exit code {proc.returncode}: {command_string(cmd)}")
    except RunnerError as error:
        run_error = error
    finally:
        stop_sync.set()
        if sync_thread is not None:
            sync_thread.join(timeout=5)
        if not flash_only:
            try:
                fetched_logs_dir = fetch_remote_smoke_logs(config)
            except RunnerError as fetch_error:
                if run_error is None:
                    raise
                print(f"warning: failed to fetch remote smoke logs: {fetch_error}", file=sys.stderr)
            else:
                if fetched_logs_dir is not None:
                    print(f"Fetched remote smoke logs to {fetched_logs_dir}")

    if run_error is not None:
        raise run_error


def run_remote_reset(config: dict[str, Any]) -> None:
    board = BOARD_PROFILES[config["board"]]
    adapter_speed = str(config["openocd_adapter_speed"])
    remote_script = """set -euo pipefail
remote_repo=$1
interface_cfg=$2
target_cfg=$3
adapter_speed=$4

cd "$remote_repo"

# Rescue DP first to clear QSPI Quad I/O mode left by overclock firmware.
openocd -f "$interface_cfg" -f target/rp2350-rescue.cfg \
    -c "adapter speed 5000" -c "init" -c "exit" 2>/dev/null || true
sleep 1

openocd -f "$interface_cfg" -f "$target_cfg" -c "adapter speed $adapter_speed" -c "init" -c "reset halt" -c "reset run" -c "exit"
"""
    cmd = ssh_base(config) + [
        "bash",
        "-s",
        "--",
        str(config["remote_repo_path"]),
        board.interface_cfg,
        board.target_cfg,
        adapter_speed,
    ]
    run_command(cmd, input_text=remote_script)


def run_remote_power_reset(config: dict[str, Any]) -> None:
    uhubctl_hub = str(config.get("uhubctl_hub", "")).strip()
    uhubctl_port = str(config.get("uhubctl_port", "")).strip()
    if not uhubctl_hub:
        raise RunnerError("uhubctl_hub must be configured for --power-reset (use 'auto' to detect)")
    remote_script = """set -euo pipefail
uhubctl_hub=$1
uhubctl_port=$2

detect_uhubctl_device() {
    local vid=${1:-2e8a}
    for dev in /sys/bus/usb/devices/*/; do
        [[ -f "$dev/idVendor" ]] || continue
        local v
        v=$(cat "$dev/idVendor" 2>/dev/null) || continue
        if [[ "$v" == "$vid" ]]; then
            local devname
            devname=$(basename "$dev")
            if [[ "$devname" == *.* ]]; then
                echo "${devname%.*} ${devname##*.}"
            else
                local bus="${devname%%-*}"
                local port="${devname#*-}"
                echo "$bus $port"
            fi
            return 0
        fi
    done
    return 1
}

uhubctl_bin=$(command -v uhubctl 2>/dev/null || echo /usr/sbin/uhubctl)
if [[ ! -x "$uhubctl_bin" ]]; then
    echo "ERROR: uhubctl not found on remote host (tried PATH and /usr/sbin)" >&2
    exit 1
fi

if [[ "$uhubctl_hub" == "auto" ]]; then
    detected=$(detect_uhubctl_device 2e8a) || { echo "ERROR: could not auto-detect USB hub for Pico" >&2; exit 1; }
    uhubctl_hub="${detected%% *}"
    if [[ -z "$uhubctl_port" ]]; then
        uhubctl_port="${detected##* }"
    fi
    # Verify uhubctl recognises this hub; walk up if not.
    if ! sudo "$uhubctl_bin" -l "$uhubctl_hub" >/dev/null 2>&1; then
        echo "Hub $uhubctl_hub not uhubctl-compatible, walking up to parent..." >&2
        if [[ "$uhubctl_hub" == *.* ]]; then
            uhubctl_port="${uhubctl_hub##*.}"
            uhubctl_hub="${uhubctl_hub%.*}"
        else
            uhubctl_port="${uhubctl_hub#*-}"
            uhubctl_hub="${uhubctl_hub%%-*}"
        fi
    fi
    echo "Auto-detected: hub=$uhubctl_hub port=$uhubctl_port"
fi

port_args=()
if [[ -n "$uhubctl_port" ]]; then
    port_args=(-p "$uhubctl_port")
fi

echo "Power-cycling USB (hub=$uhubctl_hub port=${uhubctl_port:-all})..."
sudo "$uhubctl_bin" -l "$uhubctl_hub" "${port_args[@]}" -a off -r 100
sleep 3
# After power-off the hub disappears from the bus; uhubctl may
# segfault when trying to re-scan.  Retry the 'on' command.
for _attempt in 1 2 3; do
    if sudo "$uhubctl_bin" -l "$uhubctl_hub" "${port_args[@]}" -a on -r 100 2>/dev/null; then
        break
    fi
    sleep 2
done
sleep 3
echo "Power-cycle complete."
"""
    cmd = ssh_base(config) + [
        "bash",
        "-s",
        "--",
        shlex.quote(uhubctl_hub),
        shlex.quote(uhubctl_port),
    ]
    run_command(cmd, input_text=remote_script)


def run_remote_gdb(config: dict[str, Any], remote_kernel: str, gdb_bin: str, reset_before_connect: bool) -> None:
    board = BOARD_PROFILES[config["board"]]
    adapter_speed = str(config["openocd_adapter_speed"])
    local_repo_path = REPO_ROOT.as_posix()
    openocd_init = 'openocd -f "$interface_cfg" -f "$target_cfg" -c "adapter speed $adapter_speed" -c "init"'
    if reset_before_connect:
        openocd_init += ' -c "reset halt"'
    remote_script = f"""set -euo pipefail
remote_repo={shlex.quote(str(config["remote_repo_path"]))}
local_repo={shlex.quote(local_repo_path)}
interface_cfg={shlex.quote(board.interface_cfg)}
target_cfg={shlex.quote(board.target_cfg)}
adapter_speed={shlex.quote(adapter_speed)}
gdb_bin={shlex.quote(gdb_bin)}
remote_kernel={shlex.quote(remote_kernel)}

cd "$remote_repo"

cleanup() {{
    if [[ -n "${{openocd_pid:-}}" ]]; then
        kill "$openocd_pid" 2>/dev/null || true
        wait "$openocd_pid" 2>/dev/null || true
    fi
}}

trap cleanup EXIT INT TERM

{openocd_init} >/tmp/yasos-openocd.log 2>&1 &
openocd_pid=$!

ready=0
for _ in $(seq 1 50); do
    if python3 - <<'PY'
import socket
sock = socket.socket()
sock.settimeout(0.2)
try:
    sock.connect(("127.0.0.1", 3333))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
raise SystemExit(0)
PY
    then
    ready=1
    break
    fi

    if ! kill -0 "$openocd_pid" 2>/dev/null; then
    echo "OpenOCD terminated unexpectedly. Log follows:" >&2
    cat /tmp/yasos-openocd.log >&2 || true
    exit 1
    fi
    sleep 0.2
done

if [[ "$ready" != "1" ]]; then
    echo "Timed out waiting for OpenOCD GDB server on port 3333. Log follows:" >&2
    cat /tmp/yasos-openocd.log >&2 || true
    exit 1
fi

gdb_args=(
    "$gdb_bin" "$remote_kernel"
    -ex "source scripts/yasld_gdb.py"
    -ex "directory $remote_repo"
)

if [[ "$local_repo" != "$remote_repo" ]]; then
    gdb_args+=( -ex "set substitute-path $local_repo $remote_repo" )
fi

gdb_args+=( -ex "target extended-remote :3333" )

"${{gdb_args[@]}}"
"""
    run_remote_tty_script(config, remote_script)


def run_remote_gdb_debug(
    config: dict[str, Any],
    remote_kernel: str,
    gdb_bin: str,
    target_command: str,
    gdb_script: str | None = None,
) -> None:
    """Automated GDB debug workflow:

    1. Reset target (via OpenOCD) with serial port open
    2. Wait for shell prompt on serial
    3. Send *target_command* over serial
    4. Capture all serial output (including yasld section-load log)
    5. Reset-halt target
    6. Start OpenOCD + GDB
    7. Source yasld_gdb.py, load symbols from the captured log
    8. Optionally source/run a GDB script
    9. Drop into interactive GDB (or return output if scripted)
    """
    board = BOARD_PROFILES[config["board"]]
    adapter_speed = str(config["openocd_adapter_speed"])
    serial_device = str(config.get("serial_device", "")).strip()
    local_repo_path = REPO_ROOT.as_posix()

    gdb_script_arg = ""
    if gdb_script:
        gdb_script_arg = shlex.quote(gdb_script)

    # Build the serial capture Python script as a separate string to avoid
    # nested triple-quote issues inside the bash f-string.
    serial_capture_py = r'''
import serial
import sys
import time
import subprocess

serial_device = sys.argv[1]
target_command = sys.argv[2]
log_path = sys.argv[3]

PROMPT = "$ "
TIMEOUT_BOOT = 15
TIMEOUT_CMD = 30

def drain(ser, timeout=0.5):
    old_timeout = ser.timeout
    ser.timeout = timeout
    data = b""
    while True:
        chunk = ser.read(4096)
        if not chunk:
            break
        data += chunk
    ser.timeout = old_timeout
    return data

print(f"Opening {serial_device} at 921600 baud...", file=sys.stderr)
ser = serial.Serial(serial_device, 921600, timeout=TIMEOUT_BOOT)
ser.reset_input_buffer()

print("Rescue DP reset to clear overclock state...", file=sys.stderr)
subprocess.run(
    ["openocd",
     "-f", "interface/cmsis-dap.cfg",
     "-f", "target/rp2350-rescue.cfg",
     "-c", "adapter speed 5000",
     "-c", "init",
     "-c", "exit"],
    capture_output=True, text=True, timeout=10
)
time.sleep(1)

print("Resetting target via OpenOCD...", file=sys.stderr)
result = subprocess.run(
    ["openocd",
     "-f", "interface/cmsis-dap.cfg",
     "-f", "target/rp2350.cfg",
     "-c", "adapter speed 20000",
     "-c", "init",
     "-c", "reset halt",
     "-c", "reset run",
     "-c", "exit"],
    capture_output=True, text=True, timeout=10
)
if result.returncode != 0:
    print(f"OpenOCD reset failed: {result.stderr}", file=sys.stderr)
    sys.exit(1)
print("Target reset. Waiting for boot prompt...", file=sys.stderr)

boot_output = b""
start = time.time()
while time.time() - start < TIMEOUT_BOOT:
    chunk = ser.read(1)
    if chunk:
        boot_output += chunk
        if boot_output.endswith(PROMPT.encode()):
            break
else:
    print(f"WARNING: Boot prompt not found within {TIMEOUT_BOOT}s", file=sys.stderr)
    print(f"Captured so far: {boot_output[-200:]}", file=sys.stderr)

print("Boot prompt received. Sending command...", file=sys.stderr)
ser.write((target_command + "\n").encode())

cmd_output = b""
start = time.time()
while time.time() - start < TIMEOUT_CMD:
    chunk = ser.read(1)
    if chunk:
        cmd_output += chunk
        if cmd_output.endswith(PROMPT.encode()):
            break
else:
    print(f"WARNING: Prompt not found after command within {TIMEOUT_CMD}s", file=sys.stderr)

remaining = drain(ser, timeout=0.5)
cmd_output += remaining
ser.close()

all_output = boot_output + cmd_output
with open(log_path, "wb") as f:
    f.write(all_output)

try:
    text = all_output.decode("utf-8", "ignore")
    for line in text.splitlines():
        print(f"  [serial] {line}", file=sys.stderr)
except Exception:
    pass

print(f"\nSerial log saved to {log_path} ({len(all_output)} bytes)", file=sys.stderr)
'''

    # Write the capture script to a temp file on the remote, then invoke it
    # This avoids heredoc/f-string quoting issues entirely
    import base64
    serial_script_b64 = base64.b64encode(serial_capture_py.encode()).decode()

    remote_script = f"""set -euo pipefail
remote_repo={shlex.quote(str(config["remote_repo_path"]))}
local_repo={shlex.quote(local_repo_path)}
interface_cfg={shlex.quote(board.interface_cfg)}
target_cfg={shlex.quote(board.target_cfg)}
adapter_speed={shlex.quote(adapter_speed)}
gdb_bin={shlex.quote(gdb_bin)}
remote_kernel={shlex.quote(remote_kernel)}
serial_device={shlex.quote(serial_device)}
target_command={shlex.quote(target_command)}
gdb_script={gdb_script_arg}

cd "$remote_repo"

UART_LOG=/tmp/yasos-gdb-debug-uart.log
SERIAL_PY=/tmp/yasos-gdb-serial-capture.py

cleanup() {{
    if [[ -n "${{openocd_pid:-}}" ]]; then
        kill "$openocd_pid" 2>/dev/null || true
        wait "$openocd_pid" 2>/dev/null || true
    fi
}}

trap cleanup EXIT INT TERM

# -- Detect serial device if not specified --
if [[ -z "$serial_device" ]]; then
    serial_device=$(python3 -c "
import serial.tools.list_ports
for p in serial.tools.list_ports.comports(include_links=False):
    print(p.device)
    break
" 2>/dev/null || true)
fi

if [[ -z "$serial_device" ]]; then
    echo "ERROR: No serial device found. Set serial_device in config." >&2
    exit 1
fi

echo "Using serial device: $serial_device"
echo "Target command: $target_command"

# -- Phase 1: Reset target, run command, capture serial output --
echo "Phase 1: Resetting target and capturing serial output..."

# Deploy the serial capture script
echo "{serial_script_b64}" | base64 -d > "$SERIAL_PY"

python3 "$SERIAL_PY" "$serial_device" "$target_command" "$UART_LOG"

echo ""
echo "Phase 2: Resetting target (halt) and starting GDB..."

# -- Phase 2: Reset-halt via OpenOCD, then start GDB with symbol loading --
openocd -f "$interface_cfg" -f "$target_cfg" \\
    -c "adapter speed $adapter_speed" \\
    -c "init" \\
    -c "reset halt" >/tmp/yasos-openocd.log 2>&1 &
openocd_pid=$!

ready=0
for _ in $(seq 1 50); do
    if python3 - <<'PY'
import socket
sock = socket.socket()
sock.settimeout(0.2)
try:
    sock.connect(("127.0.0.1", 3333))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
raise SystemExit(0)
PY
    then
    ready=1
    break
    fi

    if ! kill -0 "$openocd_pid" 2>/dev/null; then
    echo "OpenOCD terminated unexpectedly. Log follows:" >&2
    cat /tmp/yasos-openocd.log >&2 || true
    exit 1
    fi
    sleep 0.2
done

if [[ "$ready" != "1" ]]; then
    echo "Timed out waiting for OpenOCD GDB server on port 3333. Log follows:" >&2
    cat /tmp/yasos-openocd.log >&2 || true
    exit 1
fi

echo "OpenOCD ready. Starting GDB with symbol loading..."
echo "UART log: $UART_LOG"

# Build GDB command with yasld-load from captured log
gdb_args=(
    "$gdb_bin" "$remote_kernel"
    -ex "source scripts/yasld_gdb.py"
    -ex "directory $remote_repo"
    -ex "target extended-remote :3333"
    -ex "yasld-load $UART_LOG"
)

if [[ "$local_repo" != "$remote_repo" ]]; then
    gdb_args+=( -ex "set substitute-path $local_repo $remote_repo" )
fi

if [[ -n "$gdb_script" ]]; then
    gdb_args+=(-x "$gdb_script")
fi

"${{gdb_args[@]}}"
"""
    run_remote_tty_script(config, remote_script)


def list_boards() -> None:
    for profile in BOARD_PROFILES.values():
        print(f"{profile.key}: {profile.label}")


def collect_smoke_tests(pytest_args: list[str], with_gcc_torture: bool) -> list[str]:
    env = dict(os.environ)
    if with_gcc_torture:
        env["YASOS_SMOKE_ENABLE_GCC_TORTURE"] = "1"
    else:
        env.pop("YASOS_SMOKE_ENABLE_GCC_TORTURE", None)

    cmd = [sys.executable, "-m", "pytest", "--collect-only", "-q", *pytest_args]
    completed = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        raise RunnerError(f"Test collection failed with exit code {completed.returncode}: {command_string(cmd)}")

    collected_tests: list[str] = []
    for line in completed.stdout.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("=") or stripped.endswith(" tests collected in 0.00s"):
            continue
        if stripped.startswith("no tests collected"):
            continue
        if " tests collected in " in stripped:
            continue
        collected_tests.append(stripped)
    return collected_tests


def list_tests(args: argparse.Namespace) -> None:
    runtime_config = apply_runtime_pytest_overrides(DEFAULT_CONFIG, args)
    pytest_args = shlex.split(str(runtime_config["pytest_args"]).strip() or "tests/smoke")
    for nodeid in collect_smoke_tests(pytest_args, bool(runtime_config.get("with_gcc_torture", False))):
        print(nodeid)


def apply_runtime_pytest_overrides(config: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    runtime_config = dict(config)

    if args.test_retries is not None:
        runtime_config["test_retries"] = args.test_retries

    if args.with_gcc_torture is not None:
        runtime_config["with_gcc_torture"] = args.with_gcc_torture

    if getattr(args, "gcc_test_suite_only", False):
        runtime_config["with_gcc_torture"] = True
        runtime_config["pytest_args"] = "tests/smoke -m gcc_torture"

    if getattr(args, "profile", False):
        runtime_config["profile"] = True

    if getattr(args, "extra_tcc_cflags", None):
        runtime_config["extra_tcc_cflags"] = args.extra_tcc_cflags

    if args.pytest_args:
        runtime_config["pytest_args"] = str(args.pytest_args)
    elif args.tests:
        runtime_config["pytest_args"] = " ".join(shlex.quote(test) for test in args.tests)

    if args.log_cli_level:
        existing = str(runtime_config.get("pytest_args", "")).strip()
        runtime_config["pytest_args"] = f"{existing} --log-cli-level={shlex.quote(args.log_cli_level)}"

    return runtime_config


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build YasOS locally and run smoke tests on a remote board host.")
    parser.add_argument("--run-cached", action="store_true", help="Run immediately using cached settings without opening the TUI. This is now the default when a cache file exists.")
    parser.add_argument("--reconfigure", "--configure", dest="reconfigure", action="store_true", help="Open the TUI and update cached settings before running.")
    parser.add_argument("--debug", action="store_true", help="Build the kernel with Zig Debug optimization and pass --debug to build_rootfs.sh.")
    parser.add_argument("--force", action="store_true", help="Force a clean rootfs rebuild, refresh the remote smoke venv, and reflash kernel/rootfs even if hashes match.")
    parser.add_argument("--gdb", action="store_true", help="Build locally, sync debug artifacts to the remote repository, then start an interactive remote GDB attach session over SSH without flashing. Combine with --reset to reset-halt before attaching.")
    parser.add_argument("--flash-only", action="store_true", help="Upload and flash artifacts on the remote host, then stop without running pytest.")
    parser.add_argument("--reset", action="store_true", help="Reset the configured target through OpenOCD on the remote host before exiting, or reset-halt before attaching when combined with --gdb.")
    parser.add_argument("--power-reset", nargs="?", const="auto", default=None, metavar="HUB", help="Power-cycle the target via uhubctl on the remote host. Pass 'auto' (default) to detect the hub from the debug probe, or a hub path like '1-1'. Useful when the target is hung and OpenOCD cannot connect.")
    parser.add_argument("--test-retries", type=int, help="Retry failing smoke tests this many times. Uses pytest reruns for transient UART noise.")
    parser.add_argument("--with-gcc-torture", dest="with_gcc_torture", action="store_true", default=None, help="Enable GCC torture smoke tests for this run. Also syncs libs/tinycc/tests/gcctestsuite and exports YASOS_SMOKE_ENABLE_GCC_TORTURE=1 remotely.")
    parser.add_argument("--gcc-test-suite-only", action="store_true", help="Run only GCC torture tests. Implies --with-gcc-torture and filters pytest to -m gcc_torture.")
    parser.add_argument("--extra-tcc-cflags", help="Extra CFLAGS passed to every TCC compilation during smoke tests. Example: --extra-tcc-cflags='-O1'.")
    parser.add_argument("--pytest-args", help="Override cached pytest arguments for this run only. Example: --pytest-args 'tests/smoke -k shell_test'.")
    parser.add_argument("--tests", nargs="+", help="Run an explicit list of pytest paths or nodeids for this run only.")
    parser.add_argument("--gdb-debug", action="store_true", help="Automated GDB debug: reset target, run a command via serial, capture yasld log, reset-halt, start GDB with symbols loaded. Requires --cmd.")
    parser.add_argument("--cmd", help="Target command to execute over serial before GDB attach (used with --gdb-debug). Example: --cmd 'tcc 15_recursion.c'")
    parser.add_argument("--gdb-script", help="Path to a GDB script file to source after connecting and loading symbols (used with --gdb-debug).")
    parser.add_argument("--log-cli-level", help="Set pytest --log-cli-level for this run (e.g. INFO, DEBUG, WARNING). Passed through to the remote pytest invocation.")
    parser.add_argument("--profile", action="store_true", help="Enable TCC performance profiling. Captures per-phase bench breakdown and per-syscall cycle counts from the kernel. Results are saved alongside the timing report.")
    parser.add_argument("--force-flash", action="store_true", help="Upload and flash existing kernel/rootfs artifacts without rebuilding. Forces reflash even if remote hashes match.")
    parser.add_argument("--force-kernel-flash", action="store_true", help="Upload and flash only the kernel artifact without rebuilding. Skips rootfs entirely.")
    parser.add_argument("--list-boards", action="store_true", help="Print supported board identifiers and exit.")
    parser.add_argument("--list-tests", action="store_true", help="Print available pytest nodeids for the smoke suite and exit. Honors --tests, --pytest-args, and --with-gcc-torture.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.list_boards:
        list_boards()
        return 0
    if args.list_tests:
        list_tests(args)
        return 0

    try:
        cached = load_cache()
        cache_exists = CACHE_PATH.exists()
        apply_defconfig = args.reconfigure or not cache_exists
        if args.flash_only and args.gdb:
            raise RunnerError("--flash-only and --gdb cannot be used together")
        if args.force_flash and args.gdb:
            raise RunnerError("--force-flash and --gdb cannot be used together")
        if args.force_kernel_flash and args.gdb:
            raise RunnerError("--force-kernel-flash and --gdb cannot be used together")
        if args.gdb_debug and args.gdb:
            raise RunnerError("--gdb-debug and --gdb cannot be used together")
        if args.gdb_debug and not args.cmd:
            raise RunnerError("--gdb-debug requires --cmd to specify the target command")

        if args.reconfigure or not cache_exists:
            initial_config = cached if cache_exists else dict(DEFAULT_CONFIG)
            config = run_tui(initial_config)
            if config is None:
                return 1
            config = validate_config(config)
            save_cache(config)
        else:
            config = validate_config(cached)
            save_cache(config)

        runtime_config = apply_runtime_pytest_overrides(config, args)
        runtime_config["remote_repo_path"] = prepare_remote_repo_path(config)

        if args.power_reset is not None:
            hub_override = args.power_reset  # 'auto' or explicit hub path
            runtime_config["uhubctl_hub"] = hub_override
            print(f"Running remote USB power-cycle reset (hub={hub_override}).")
            run_remote_power_reset(runtime_config)
            print("Remote power-cycle reset completed successfully.")
            return 0

        if args.reset and not args.gdb:
            print("Running remote OpenOCD reset with cached configuration.")
            run_remote_reset(runtime_config)
            print("Remote reset completed successfully.")
            return 0

        if args.force_flash:
            if not KERNEL_ARTIFACT.exists():
                raise RunnerError(f"Kernel artifact not found: {KERNEL_ARTIFACT}. Build first.")
            if not ROOTFS_ARTIFACT.exists():
                raise RunnerError(f"Rootfs artifact not found: {ROOTFS_ARTIFACT}. Build first.")
            print("Force-flashing existing artifacts (skipping build).")
            kernel_sha = sha256_file(KERNEL_ARTIFACT)
            rootfs_sha = sha256_file(ROOTFS_ARTIFACT)
            requirements_sha = sha256_file(SMOKE_REQUIREMENTS)
            remote_work_dir, remote_kernel, remote_rootfs = upload_artifacts(runtime_config)
            run_remote_smoke(
                runtime_config,
                remote_work_dir,
                remote_kernel,
                remote_rootfs,
                flash_only=True,
                kernel_sha=kernel_sha,
                rootfs_sha=rootfs_sha,
                requirements_sha=requirements_sha,
                force=True,
            )
            print("Force-flash completed successfully.")
            return 0

        if args.force_kernel_flash:
            if not KERNEL_ARTIFACT.exists():
                raise RunnerError(f"Kernel artifact not found: {KERNEL_ARTIFACT}. Build first.")
            print("Force-flashing kernel only (skipping build and rootfs).")
            kernel_sha = sha256_file(KERNEL_ARTIFACT)
            requirements_sha = sha256_file(SMOKE_REQUIREMENTS)
            remote_work_dir, remote_kernel = upload_kernel_artifact(runtime_config)
            run_remote_smoke(
                runtime_config,
                remote_work_dir,
                remote_kernel,
                "",
                flash_only=True,
                kernel_sha=kernel_sha,
                rootfs_sha="",
                requirements_sha=requirements_sha,
                force=True,
                kernel_only=True,
            )
            print("Force kernel flash completed successfully.")
            return 0

        if args.gdb_debug:
            print("Detecting remote debug tools.")
            gdb_bin = detect_remote_debug_tools(runtime_config)
            print(f"Using remote GDB binary: {gdb_bin}")
            print(f"Target command: {args.cmd}")
            if args.gdb_script:
                print(f"GDB script: {args.gdb_script}")
            build_local_artifacts(
                runtime_config,
                debug=args.debug,
                build_rootfs=False,
                force=args.force,
                apply_defconfig=apply_defconfig,
            )
            print("Syncing repository source files to the remote repository with rsync.")
            sync_remote_repo_sources(runtime_config)
            print("Syncing debug artifacts and symbol files to the remote repository with rsync.")
            synced_remote_kernel = sync_debug_artifacts(runtime_config)
            remote_kernel, using_flashed_kernel = select_remote_gdb_kernel(runtime_config, synced_remote_kernel)
            if using_flashed_kernel:
                print(f"Using flashed remote kernel symbol file: {remote_kernel}")
            else:
                print(f"Using synced remote kernel symbol file: {remote_kernel}")
            run_remote_gdb_debug(
                runtime_config,
                remote_kernel,
                gdb_bin,
                target_command=args.cmd,
                gdb_script=args.gdb_script,
            )
            print("Remote GDB debug session finished.")
            return 0

        if args.gdb:
            print("Detecting remote debug tools.")
            gdb_bin = detect_remote_debug_tools(runtime_config)
            print(f"Using remote GDB binary: {gdb_bin}")
            if args.reset:
                print("Running remote GDB attach workflow with reset-before-connect.")
            else:
                print("Running remote GDB attach workflow with synced kernel symbols.")
            build_local_artifacts(
                runtime_config,
                debug=args.debug,
                build_rootfs=False,
                force=args.force,
                apply_defconfig=apply_defconfig,
            )
            print("Syncing repository source files to the remote repository with rsync.")
            sync_remote_repo_sources(runtime_config)
            print("Syncing debug artifacts and symbol files to the remote repository with rsync.")
            synced_remote_kernel = sync_debug_artifacts(runtime_config)
            remote_kernel, using_flashed_kernel = select_remote_gdb_kernel(runtime_config, synced_remote_kernel)
            if using_flashed_kernel:
                print(f"Using flashed remote kernel symbol file: {remote_kernel}")
            else:
                print(f"Using synced remote kernel symbol file: {remote_kernel}")
            run_remote_gdb(runtime_config, remote_kernel, gdb_bin, reset_before_connect=args.reset)
            print("Remote GDB session finished.")
            return 0

        if args.debug:
            print("Running remote smoke workflow with debug kernel and rootfs builds.")
        else:
            print("Running remote smoke workflow with cached configuration.")
        total_steps = 3 if args.flash_only else 4
        step = 1
        print(f"[{step}/{total_steps}] Building local artifacts...")
        build_local_artifacts(
            runtime_config,
            debug=args.debug,
            force=args.force,
            apply_defconfig=apply_defconfig,
        )
        kernel_sha = sha256_file(KERNEL_ARTIFACT)
        rootfs_sha = sha256_file(ROOTFS_ARTIFACT)
        requirements_sha = sha256_file(SMOKE_REQUIREMENTS)
        step += 1
        print(f"[{step}/{total_steps}] Uploading artifacts to remote host...")
        remote_work_dir, remote_kernel, remote_rootfs = upload_artifacts(runtime_config)
        if not args.flash_only:
            step += 1
            print(f"[{step}/{total_steps}] Syncing repository source files to the remote repository with rsync.")
            sync_smoke_support(runtime_config)
        step += 1
        print(f"[{step}/{total_steps}] Running remote smoke tests...")
        run_remote_smoke(
            runtime_config,
            remote_work_dir,
            remote_kernel,
            remote_rootfs,
            flash_only=args.flash_only,
            kernel_sha=kernel_sha,
            rootfs_sha=rootfs_sha,
            requirements_sha=requirements_sha,
            force=args.force,
        )
    except RunnerError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130

    print("Remote smoke workflow completed successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
