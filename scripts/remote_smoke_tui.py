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
import re
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
DEFCONFIG_HASH_PATH = REPO_ROOT / ".cache" / "defconfig_hash"
GENERATED_CONFIG_PATH = REPO_ROOT / "config" / "target" / ".config"
SMOKE_REQUIREMENTS = REPO_ROOT / "tests" / "smoke" / "requirements.txt"

# Flash artifacts, the pytest venv and the flashed-sha state live in a work dir
# INSIDE the remote repository (single configured remote path).  It holds
# remote-only state that has no local counterpart, so the source rsync must
# exclude it — see sync_remote_repo_sources().
REMOTE_WORK_DIR_NAME = "workdir"

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
    "apps/syscallbench",
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


def _defconfig_hash(defconfig_rel: str) -> str:
    """Hash the active defconfig file (plus its path) so edits are detected."""
    digest = hashlib.sha256()
    digest.update(defconfig_rel.encode())
    try:
        digest.update((REPO_ROOT / defconfig_rel).read_bytes())
    except OSError:
        pass
    return digest.hexdigest()


def _defconfig_is_up_to_date(defconfig_rel: str) -> bool:
    """True when the generated .config exists and was built from this defconfig.

    Returns False whenever the defconfig content changed, the generated config
    is missing, or we have no record of the last-built defconfig — any of which
    must trigger a defconfig regeneration plus a full rebuild.
    """
    if not GENERATED_CONFIG_PATH.exists():
        return False
    if not DEFCONFIG_HASH_PATH.exists():
        return False
    return DEFCONFIG_HASH_PATH.read_text().strip() == _defconfig_hash(defconfig_rel)


def _save_defconfig_hash(defconfig_rel: str) -> None:
    DEFCONFIG_HASH_PATH.parent.mkdir(parents=True, exist_ok=True)
    DEFCONFIG_HASH_PATH.write_text(_defconfig_hash(defconfig_rel) + "\n")


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

# tcc -O levels the smoke suites can be run at. The suites iterate whatever is
# selected (tests2, ir_tests and gcc-torture all read
# YASOS_SMOKE_TCC_OPT_LEVELS), so a selection of several is a full matrix run,
# not just a different flag on one pass.
SMOKE_TCC_OPT_LEVEL_OPTIONS = ["-O0", "-O1", "-O2"]
SMOKE_TCC_ALL_OPT_LEVELS = " ".join(SMOKE_TCC_OPT_LEVEL_OPTIONS)
# What the TUI cycles through, and the shorthands --smoke-tcc-opt-levels takes.
# The whole matrix is first because it is the default: remote smoke gates real
# silicon, and a level that is never run there is a level the board never
# proves. Single levels follow, for a focused run (roughly a third of the wall
# time) while chasing one -O layer.
SMOKE_TCC_OPT_LEVEL_PRESETS = [SMOKE_TCC_ALL_OPT_LEVELS, "-O0", "-O1", "-O2"]

# Cache-format version, stamped into .cache/remote_smoke_runner.json. Bump it
# when a default changes in a way an older cache would otherwise pin to the
# previous behaviour, and add the migration to migrate_cached_config().
CONFIG_VERSION = 2


def normalize_smoke_tcc_opt_levels(value: Any) -> str:
    """Normalize an -O level selection into the space-separated env-var form.

    Accepts what the suites' own parser accepts -- "-O0", "O0", "0", separated
    by spaces or commas -- plus "all" for the whole matrix, and returns e.g.
    "-O0 -O2" with duplicates dropped and order preserved. Raises ValueError on
    anything that is not a supported level, so a typo fails at the flag rather
    than silently running a different set on the board.
    """
    text = "" if value is None else str(value).strip()
    if not text:
        return ""

    levels: list[str] = []
    for token in re.split(r"[\s,]+", text):
        if not token:
            continue
        if token.lower() == "all":
            for level in SMOKE_TCC_OPT_LEVEL_OPTIONS:
                if level not in levels:
                    levels.append(level)
            continue
        normalized = token if token.startswith("-O") else f"-O{token.lstrip('-O')}"
        if normalized not in SMOKE_TCC_OPT_LEVEL_OPTIONS:
            raise ValueError(
                f"unsupported tcc optimization level '{token}'; "
                f"expected any of {', '.join(SMOKE_TCC_OPT_LEVEL_OPTIONS)} (or 'all')"
            )
        if normalized not in levels:
            levels.append(normalized)
    return " ".join(levels)

# Serial console line rate, for this script and for every remote script it
# generates. Must match the target's `console_baudrate`
# (source/kernel/drivers/uart/uart_driver.zig) and CONSOLE_BAUDRATE in
# tests/smoke/framework/session.py -- a mismatch does not fail loudly, it just
# turns the console into garbage.
#
# 3 Mbaud is the target PL011's ceiling: clk_peri/(16*divisor) with clk_peri at
# 48 MHz and the divisor bottoming out at 1. It is exact, unlike 921600.
#
# This was 460800 until the rig's debug probe was reflashed off debugprobe
# 2.0.1, which predates the v2.2.1/v2.2.2 UART-TX fixes; at 921600 that firmware
# was measured dropping 32-48 bytes out of roughly every fourth bulk-transfer
# burst, with the target's own counters showing no overrun, no ring drop and no
# framing error. See docs/remote_smoke_speedup_plan.md.
CONSOLE_BAUDRATE = 3000000

DEFAULT_CONFIG = {
    "board": "pimoroni_pico_plus2_and_vga",
    "ssh_target": "",
    "ssh_port": 22,
    "ssh_identity_file": "",
    "openocd_adapter_speed": 20000,
    "remote_repo_path": "~/yasos_remote_smoke",
    "serial_device": "",
    "optimize": "ReleaseFast",
    "smoke_tcc_opt_level": SMOKE_TCC_ALL_OPT_LEVELS,
    "test_retries": 1,
    "with_gcc_torture": True,
    "pytest_args": "tests/smoke",
    "uhubctl_hub": "",
    "uhubctl_port": "",
    # Numbered run directories kept on the remote (logs/1, logs/2, ...); 0 keeps
    # all of them. The local mirror is never pruned.
    "keep_runs": 20,
}


class RunnerError(RuntimeError):
    pass


def normalize_uhubctl_ports(value: Any) -> str:
    """Normalize a uhubctl port spec into uhubctl's comma-separated form.

    Accepts a single port ("2"), a space/comma/semicolon-separated list
    ("1 2", "1,2", "1;2"), or a range ("1-2"), and returns a canonical
    comma-separated string ("1,2"). uhubctl's -p flag accepts this form
    natively, so several ports (e.g. the debug probe on port 1 and the
    target board on port 2) are power-cycled together by one reset.

    Unrecognised tokens are dropped; an empty/invalid spec returns "" which
    means "let auto-detect choose" (or "cycle the whole hub" when ganged).
    """
    if value is None:
        return ""
    text = str(value).strip()
    if not text:
        return ""
    ports: list[str] = []
    for tok in re.split(r"[\s,;]+", text):
        tok = tok.strip()
        if not tok:
            continue
        # Single ports ("2") and ranges ("1-2") are valid uhubctl specs; pass
        # them through. Anything else is a typo — skip rather than feed garbage
        # to uhubctl (which would error out and abort the whole reset).
        if re.fullmatch(r"\d+(-\d+)?", tok):
            if tok not in ports:
                ports.append(tok)
    return ",".join(ports)


def effective_optimize(config: dict[str, Any], debug: bool) -> str:
    return "Debug" if debug else str(config["optimize"])


def merge_config(data: dict[str, Any] | None) -> dict[str, Any]:
    merged = dict(DEFAULT_CONFIG)
    if data:
        merged.update(data)
    # Obsolete: the work dir is no longer configurable, it is derived from the
    # single configured remote repo path.  Drop it from older cache files.
    merged.pop("remote_work_dir", None)
    if merged.get("board") not in BOARD_PROFILES:
        merged["board"] = DEFAULT_CONFIG["board"]
    if merged.get("optimize") not in OPTIMIZE_OPTIONS:
        merged["optimize"] = DEFAULT_CONFIG["optimize"]
    # Any subset of the supported levels is valid, in any of the accepted
    # spellings, so this normalizes rather than tests for membership. An
    # unparsable cached value falls back to the default instead of aborting the
    # run -- the cache is written by this script, not hand-edited, and a bad
    # value there should not wedge the runner.
    try:
        normalized_opt_levels = normalize_smoke_tcc_opt_levels(merged.get("smoke_tcc_opt_level"))
    except ValueError:
        normalized_opt_levels = ""
    merged["smoke_tcc_opt_level"] = normalized_opt_levels or DEFAULT_CONFIG["smoke_tcc_opt_level"]
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
    try:
        merged["keep_runs"] = int(merged.get("keep_runs", DEFAULT_CONFIG["keep_runs"]))
    except (TypeError, ValueError):
        merged["keep_runs"] = DEFAULT_CONFIG["keep_runs"]
    # Default on (matches DEFAULT_CONFIG): the GCC torture suite runs unless a
    # config/CLI explicitly disables it.
    merged["with_gcc_torture"] = str(merged.get("with_gcc_torture", True)).strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    } if not isinstance(merged.get("with_gcc_torture"), bool) else bool(merged.get("with_gcc_torture"))
    merged.setdefault("uhubctl_hub", "")
    merged.setdefault("uhubctl_port", "")
    # The port field may carry several ports (e.g. "1,2" for the debug probe
    # plus the target board on the Waveshare power-switching hub). Canonicalize
    # to uhubctl's comma form so every reset path power-cycles them together.
    merged["uhubctl_port"] = normalize_uhubctl_ports(merged.get("uhubctl_port"))
    merged["config_version"] = CONFIG_VERSION
    return merged


def migrate_cached_config(data: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Bring a settings cache written by an older runner up to CONFIG_VERSION.

    Returns the migrated data plus one note per applied migration, for the
    runner to print -- a settings file changing under the user deserves a line
    saying so.
    """
    migrated = dict(data)
    notes: list[str] = []
    try:
        version = int(migrated.get("config_version", 1))
    except (TypeError, ValueError):
        version = 1

    # v1 -> v2: the runner ran one -O level (default -O0) while the QEMU gate
    # and the packaged hardware run both covered -O0/-O1/-O2, so the board --
    # the only place the real silicon is exercised -- was the one place two of
    # the three levels never ran. Only the exact old default is moved up: a
    # cache holding -O1 or -O2 differs from it, so somebody chose that.
    if version < 2 and str(migrated.get("smoke_tcc_opt_level", "")).strip() == "-O0":
        migrated["smoke_tcc_opt_level"] = SMOKE_TCC_ALL_OPT_LEVELS
        notes.append(
            f"Smoke TCC opt levels upgraded from the old -O0 default to "
            f"'{SMOKE_TCC_ALL_OPT_LEVELS}'; pass --smoke-tcc-opt-levels -O0 for a single-level run."
        )

    migrated["config_version"] = CONFIG_VERSION
    return migrated, notes


def load_cache() -> dict[str, Any]:
    if not CACHE_PATH.exists():
        return dict(DEFAULT_CONFIG)
    try:
        with CACHE_PATH.open("r", encoding="utf-8") as handle:
            cached = json.load(handle)
    except json.JSONDecodeError as error:
        raise RunnerError(f"Cache file is not valid JSON: {CACHE_PATH} ({error})") from error
    migrated, notes = migrate_cached_config(cached)
    for note in notes:
        print(f"note: {note}")
    return merge_config(migrated)


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
    if validated["keep_runs"] < 0:
        raise RunnerError("Kept run directories must be zero (keep all) or greater")

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


def cycle_smoke_tcc_opt_levels(current: str, direction: int) -> str:
    """Step through the -O level presets, tolerating a custom selection.

    --smoke-tcc-opt-levels accepts combinations the presets do not list (e.g.
    "-O0 -O2"), and one of those can end up cached, so unlike cycle_option this
    cannot assume the current value is in the list -- it lands on the default
    instead of raising.
    """
    try:
        normalized = normalize_smoke_tcc_opt_levels(current)
    except ValueError:
        normalized = ""
    if normalized not in SMOKE_TCC_OPT_LEVEL_PRESETS:
        return SMOKE_TCC_OPT_LEVEL_PRESETS[0]
    return cycle_option(SMOKE_TCC_OPT_LEVEL_PRESETS, normalized, direction)


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
            ("Serial device", "serial_device"),
            ("Optimize", "optimize"),
            ("Smoke TCC opt lvls", "smoke_tcc_opt_level"),
            ("Test retries", "test_retries"),
            ("Keep remote run dirs", "keep_runs"),
            ("With GCC torture", "with_gcc_torture"),
            ("Pytest args", "pytest_args"),
            ("uhubctl hub (auto)", "uhubctl_hub"),
            ("uhubctl port(s) e.g. 1,2", "uhubctl_port"),
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
                elif selected_key == "smoke_tcc_opt_level":
                    config[selected_key] = cycle_smoke_tcc_opt_levels(str(config[selected_key]), -1)
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
                elif selected_key == "smoke_tcc_opt_level":
                    config[selected_key] = cycle_smoke_tcc_opt_levels(str(config[selected_key]), 1)
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
                if selected_key == "smoke_tcc_opt_level":
                    config[selected_key] = cycle_smoke_tcc_opt_levels(str(config[selected_key]), 1)
                    continue
                if selected_key == "with_gcc_torture":
                    config[selected_key] = not bool(config[selected_key])
                    continue
                edited = edit_value(stdscr, label, str(config[selected_key]))
                if selected_key in ("ssh_port", "openocd_adapter_speed", "test_retries", "keep_runs"):
                    if selected_key == "ssh_port":
                        default_value = "22"
                    elif selected_key == "openocd_adapter_speed":
                        default_value = "20000"
                    elif selected_key == "keep_runs":
                        default_value = str(DEFAULT_CONFIG["keep_runs"])
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
    # Include ad-hoc python/gdb debug scripts kept under scripts/.
    for script_name in ("catch_r9_zero.py", "probe_svc_sp.py", "catch_pc0.py", "catch_malloc_r9.py", "catch_sp_zero.py"):
        candidate = REPO_ROOT / "scripts" / script_name
        if candidate.exists():
            paths.append(candidate.relative_to(REPO_ROOT).as_posix())
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
        # The work dir lives inside the remote repo but has no local
        # counterpart: without this exclude --delete wipes the uploaded
        # kernel/rootfs.img, the flashed-sha state and the pytest venv right
        # after upload_artifacts() put them there, and the flash step then
        # fails with "couldn't open <work dir>/rootfs.img".
        f"--exclude=/{REMOTE_WORK_DIR_NAME}/",
        "--exclude=.git/",
        "--exclude=.pytest_cache/",
        "--exclude=.cache/",
        "--exclude=.gdbhistory",
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


def ensure_gcc_torture_submodule(config: dict[str, Any]) -> None:
    """Fetch the gcc-testsuite submodule when GCC torture tests are enabled but
    the c-torture tree is missing (submodule never initialized)."""
    if not bool(config.get("with_gcc_torture", False)):
        return
    tinycc_dir = REPO_ROOT / "libs" / "tinycc"
    torture_dir = (
        tinycc_dir / "tests" / "gcctestsuite" / "gcc-testsuite" / "gcc" / "testsuite" / "gcc.c-torture"
    )
    if torture_dir.is_dir():
        return
    print("GCC torture tests enabled but submodule not fetched; initializing gcc-testsuite...")
    run_command(
        ["git", "submodule", "update", "--init", "--depth", "1", "tests/gcctestsuite/gcc-testsuite"],
        cwd=tinycc_dir,
    )
    if not torture_dir.is_dir():
        raise RunnerError(
            "gcc-testsuite submodule was initialized but "
            f"{torture_dir.relative_to(REPO_ROOT)} is still missing."
        )


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
    ensure_gcc_torture_submodule(config)
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


def local_smoke_logs_dir(config: dict[str, Any]) -> Path:
    """Local mirror of the remote runs root, one directory per ssh target."""
    return REMOTE_SMOKE_LOGS_DIR / safe_path_component(str(config["ssh_target"]))


def remote_runs_root(config: dict[str, Any]) -> str:
    """Where the numbered run directories live on the remote host.

    Inside the work dir, because the repo tree above it is rsynced with
    --delete: a runs root under $remote_repo would be deleted at the start of
    every run, and the run before it would silently hand its number back.
    """
    remote_repo = str(config["remote_repo_path"]).rstrip("/")
    return f"{remote_work_dir_of(remote_repo)}/logs"


def allocate_remote_run_id(config: dict[str, Any]) -> int:
    """Reserve the next run number under the remote ``logs/``.

    Allocated here rather than remotely so the local side knows the directory
    before the run starts: the log mirror and the tailer are scoped to it, which
    is what lets a run be followed live without confusing it with the previous
    run's transcripts.
    """
    remote_script = """set -euo pipefail
runs_root=$1

mkdir -p "$runs_root"
max=0
for entry in "$runs_root"/*; do
    name=${entry##*/}
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    [[ "$name" =~ ^[0-9]+$ ]] || continue
    if (( 10#$name > max )); then
        max=$(( 10#$name ))
    fi
done
echo $(( max + 1 ))
"""
    completed = subprocess.run(
        ssh_base(config) + ["bash", "-s", "--", remote_runs_root(config)],
        input=remote_script,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RunnerError(
            f"Could not allocate a remote run id: {completed.stderr.strip()}"
        )
    try:
        return int(completed.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise RunnerError(
            f"Unexpected remote run id: {completed.stdout.strip()!r}"
        ) from None


def fetch_remote_smoke_logs(config: dict[str, Any], run_id: int | None = None) -> Path | None:
    remote_logs_dir = remote_runs_root(config)
    local_logs_dir = local_smoke_logs_dir(config)

    # Not wiped, and synced without --delete: the mirror holds one directory per
    # run, and keeping the earlier ones is the reason they are numbered. It
    # therefore outlives the remote's own retention (keep_runs), which is what
    # makes a baseline safe to compare against weeks later.
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
    if run_id is not None and (local_logs_dir / str(run_id)).is_dir():
        return local_logs_dir / str(run_id)
    return local_logs_dir


def _quiet_log_sync(config: dict[str, Any]) -> bool:
    """Rsync remote logs to local without printing commands. True when it worked.

    The remote ``Session`` flushes its log file after every write, so a test
    that is still running (or wedged) already has its output on disk remotely --
    this pulls that partial file down so it can be tailed live.

    No --delete: the run being followed lives in its own numbered directory, so
    a previous run's transcripts can no longer be mistaken for this one's (which
    is what --delete used to prevent), and mirroring the remote's pruning would
    throw away local history for nothing.
    """
    remote_logs_dir = remote_runs_root(config)
    local_logs_dir = local_smoke_logs_dir(config)
    local_logs_dir.mkdir(parents=True, exist_ok=True)

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
    return completed.returncode == 0


# Seconds a test has to stay in flight before its log starts streaming, how many
# already-written lines are replayed as context when streaming starts, and how
# often a stream with no new output says so.
LOG_STREAM_AFTER_SECONDS = 30.0
LOG_STREAM_CONTEXT_LINES = 40
LOG_STREAM_IDLE_NOTICE_SECONDS = 60.0

_STDOUT_LOCK = threading.Lock()


def format_duration(seconds: float) -> str:
    """Render *seconds* the way the remote RUNNING lines do: ``0.42s``, ``2m03s``."""
    if seconds < 10.0:
        return f"{seconds:.2f}s"
    if seconds < 60.0:
        return f"{seconds:.1f}s"
    minutes, remainder = divmod(int(round(seconds)), 60)
    return f"{minutes}m{remainder:02d}s"


def _emit(text: str) -> None:
    """Write a whole line to stdout without interleaving into pytest's output."""
    with _STDOUT_LOCK:
        sys.stdout.write(text if text.endswith("\n") else text + "\n")
        sys.stdout.flush()


class _LogTailer:
    """Announce fetched logs and stream the in-flight test's log while it runs.

    Every synced log file is tracked by size, and the newest one (by mtime) is
    taken to be the test currently in flight -- remote ``Session`` objects open
    their log file in ``pytest_runtest_setup``, so the newest file is the test
    pytest is on.  Fast tests come and go silently; once one has been in flight
    for ``stream_after`` seconds it is clearly the interesting one, so its tail
    is replayed and everything appended to it afterwards is printed as it
    arrives.  That is the whole point: the serial transcript of a stuck test is
    visible *while* it is stuck, instead of only after it times out.

    ``logs_dir`` is *this run's* numbered directory in the local mirror, so
    everything in it belongs to the run being followed and no previous run's
    transcript can be mistaken for the in-flight one.  Streaming still stays off
    until the remote pytest phase is known to have started; two independent
    signals turn it on, whichever lands first: pytest's own session banner in
    the runner's output, and the first log file appearing in the run directory
    (the remote creates it after flashing, immediately before pytest).
    """

    def __init__(
        self,
        logs_dir: Path,
        stream_after: float = LOG_STREAM_AFTER_SECONDS,
        clock: Any = time.monotonic,
    ):
        self._logs_dir = logs_dir
        self._stream_after = stream_after
        self._clock = clock
        self._sizes: dict[Path, int] = {}
        # Announcing is tracked apart from the byte offsets: the in-flight log
        # holds no offset until it starts streaming, and must not be re-reported
        # as newly fetched on every poll until then.
        self._seen: set[Path] = set()
        self._active: Path | None = None
        self._active_since = 0.0
        self._streaming = False
        self._last_output_at = 0.0
        self._enabled = False
        self._enabled_at = 0.0
        # A file already in the run directory cannot belong to this run -- the
        # remote creates that directory after flashing, and its number was
        # allocated as one past the highest existing one. It can only be a
        # leftover in the local mirror from a remote whose logs/ was wiped by
        # hand and started numbering again, so it is excluded outright rather
        # than announced, streamed, or taken as the signal that pytest started.
        self._stale: set[Path] = set()
        if self._logs_dir.exists():
            self._stale = set(self._logs_dir.glob("*.txt"))

    @property
    def streaming(self) -> bool:
        return self._streaming

    @property
    def enabled(self) -> bool:
        return self._enabled

    def note_output(self, line: str) -> None:
        """Called with each line of the runner's output, to spot pytest starting."""
        if not self._enabled and "test session starts" in line:
            self._enable()

    def _enable(self) -> None:
        # Called from the reader thread as well as the sync thread; both only
        # ever set the flag, and the timestamp makes the in-flight test's
        # threshold count from here rather than from a pre-pytest observation.
        # Idempotent: whichever signal lands first fixes the timestamp, and a
        # later one must not push it forward and delay streaming.
        if self._enabled:
            return
        self._enabled_at = self._clock()
        self._enabled = True

    def poll(self) -> None:
        if not self._logs_dir.exists():
            return
        now = self._clock()
        candidates: list[tuple[float, Path, int]] = []
        new_files = 0
        for path in sorted(self._logs_dir.glob("*.txt")):
            if path in self._stale:
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            if path not in self._seen:
                self._seen.add(path)
                new_files += 1
            candidates.append((stat.st_mtime, path, stat.st_size))

        # A file in the run directory can only have come from this run, so its
        # arrival means the remote is past flashing and into pytest.
        if new_files:
            self._enable()

        # Drop bookkeeping for files that are gone (a rerun that recreates the
        # run directory); a later file reusing the name starts from offset 0.
        present = {path for _, path, _ in candidates}
        self._seen &= present
        for path in [p for p in self._sizes if p not in present]:
            del self._sizes[path]

        if new_files:
            total = sum(1 for _ in self._logs_dir.rglob("*.txt"))
            _emit(f"[log sync] {new_files} new log(s) fetched ({total} total in {self._logs_dir})")

        if not candidates:
            return
        _, newest, newest_size = max(candidates, key=lambda item: (item[0], str(item[1])))

        if newest != self._active:
            self._active = newest
            self._active_since = now
            self._streaming = False

        if self._streaming:
            self._stream_new_output(newest, newest_size, now)
        elif self._enabled and self._stream_after > 0.0:
            if now - self._in_flight_since() >= self._stream_after:
                self._start_streaming(newest, newest_size, now)

        # Anything that is not the in-flight log is consumed silently: replaying
        # every finished test's transcript would bury the run's own output.
        for _, path, size in candidates:
            if path != newest:
                self._sizes[path] = size

    def _in_flight_since(self) -> float:
        """When the active log started counting as the in-flight test's log.

        A log fetched before pytest started (i.e. before streaming was enabled)
        counts from the moment it was enabled, so the reported elapsed time is
        never longer than the test has actually been running.
        """
        return max(self._active_since, self._enabled_at)

    def _start_streaming(self, path: Path, size: int, now: float) -> None:
        self._streaming = True
        self._last_output_at = now
        elapsed = format_duration(now - self._in_flight_since())
        _emit(f"[log tail] {path.name} still running after {elapsed}; streaming its log")
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        lines = text.splitlines()
        if len(lines) > LOG_STREAM_CONTEXT_LINES:
            _emit(f"[log tail] ... {len(lines) - LOG_STREAM_CONTEXT_LINES} earlier line(s) omitted")
            lines = lines[-LOG_STREAM_CONTEXT_LINES:]
        for line in lines:
            _emit(f"  | {line}")
        self._sizes[path] = size

    def _stream_new_output(self, path: Path, size: int, now: float) -> None:
        offset = self._sizes.get(path, 0)
        if size < offset:
            # Truncated/rewritten under us; resync from the start of the file.
            offset = 0
        if size > offset:
            try:
                with path.open("rb") as handle:
                    handle.seek(offset)
                    chunk = handle.read(size - offset)
            except OSError:
                return
            self._sizes[path] = size
            self._last_output_at = now
            for line in chunk.decode("utf-8", errors="replace").splitlines():
                _emit(f"  | {line}")
        elif (
            LOG_STREAM_IDLE_NOTICE_SECONDS > 0.0
            and now - self._last_output_at >= LOG_STREAM_IDLE_NOTICE_SECONDS
        ):
            self._last_output_at = now
            idle = format_duration(now - self._in_flight_since())
            _emit(f"[log tail] {path.name}: no new output, {idle} in flight")


def _background_log_sync(
    config: dict[str, Any],
    stop_event: threading.Event,
    tailer: _LogTailer,
    interval: float = 10.0,
    streaming_interval: float = 5.0,
) -> None:
    """Periodically sync remote logs in a background thread and tail the live one."""
    while not stop_event.is_set():
        stop_event.wait(streaming_interval if tailer.streaming else interval)
        if stop_event.is_set():
            break
        try:
            if _quiet_log_sync(config):
                tailer.poll()
        except Exception:
            pass


def prepare_remote_repo_path(config: dict[str, Any]) -> str:
    """Expand the configured remote repo path remotely, create it together with
    its work dir, and return the absolute path."""
    requested = str(config["remote_repo_path"]).strip()
    if not requested:
        raise RunnerError("Remote repository path is required")
    remote_script = """set -euo pipefail
path=$1
work_dir_name=$2

if [[ $path == "~" ]]; then
  path="$HOME"
elif [[ $path == ~/* ]]; then
  path="$HOME/${path#~/}"
fi

mkdir -p "$path/$work_dir_name"

printf '%s\n' "$path"
"""
    return capture_command(
        ssh_base(config) + ["bash", "-s", "--", requested, REMOTE_WORK_DIR_NAME],
        input_text=remote_script,
    )


def remote_work_dir_of(remote_repo: str) -> str:
    return f"{remote_repo.rstrip('/')}/{REMOTE_WORK_DIR_NAME}"


def prepare_remote_work_dir(config: dict[str, Any]) -> str:
    """Return the remote work dir, creating it (and the repo) if missing.

    Artifacts are scp'd here before the flash script runs, so the directory has
    to exist by then — scp does not create it.
    """
    return remote_work_dir_of(prepare_remote_repo_path(config))


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
    # Always regenerate config/target/.config from THIS board's defconfig before
    # building. The cached config/target is shared global state: a parallel session
    # (e.g. a QEMU run) can repoint it to another board, and the defconfig-hash check
    # below only detects edits to *this* defconfig file, not an external board switch
    # — so without this we would silently build+flash the wrong target. `zig build`
    # is content-cached, so when the config is already correct this is a no-op rebuild.
    # `apply_defconfig` is kept only to force a from-scratch rebuild when the defconfig
    # itself changed (handled by the caller via the rootfs/kernel staleness checks).
    _ = apply_defconfig
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
    # Record the defconfig we just regenerated from so the next run can
    # detect edits and force another full rebuild.
    _save_defconfig_hash(board.defconfig)
    if config.get("profile"):
        if _set_kconfig_option("CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING"):
            print("Enabled CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING for profiling.")
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
    rerun_failed: bool = False,
) -> None:
    board = BOARD_PROFILES[config["board"]]
    adapter_speed = str(config["openocd_adapter_speed"])
    test_retries = int(config.get("test_retries", 0))
    pytest_args = shlex.split(str(config["pytest_args"]).strip() or "tests/smoke")
    keep_runs = int(config.get("keep_runs", DEFAULT_CONFIG["keep_runs"]))
    # A flash-only run never reaches the pytest phase, so it neither needs nor
    # should consume a run number.
    run_id = 0 if flash_only else allocate_remote_run_id(config)
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
rerun_failed=${13}
kernel_sha=${14}
rootfs_sha=${15}
requirements_sha=${16}
force=${17}
profile=${18}
uhubctl_hub=${19}
uhubctl_port=${20}
kernel_only=${21}
smoke_tcc_opt_level=${22}
extra_tcc_cflags=${23}
seed_source_manifest=${24}
tcc_env_prefix=${25}
run_id=${26}
keep_runs=${27}
shift 27

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
    # uhubctl_port may name several ports (e.g. "1,2" for the debug probe plus
    # the target board on the Waveshare power-switching hub); an explicitly
    # configured port spec is preserved here and passed through to uhubctl -p.
    # If the detected hub is not uhubctl-compatible, walk up to the root hub.
    #
    # On Raspberry Pi 4 the internal VIA VL805 hub (1-1) does NOT support
    # per-port power switching.  We must power off ALL ports together with
    # "uhubctl -l 1-1 -a 0" (no -p flag).  To detect this, we check whether
    # the hub reports "ganged" power switching and clear uhubctl_port if so.
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

            # Check if the hub supports per-port power switching.
            # If uhubctl reports "ganged" switching, per-port control won't
            # work (e.g. Raspberry Pi 4 VIA VL805).  Clear the port so we
            # power-cycle ALL ports together with "uhubctl -l <hub> -a 0".
            # Only inspect the target hub's OWN status header ("Current status
            # for hub ..."), not its connected-device/port lines — a per-port
            # (ppps) root hub can have a *ganged* child hub plugged into it
            # (e.g. a Waveshare hub on a Pi 5 root port), and matching that
            # child's "ganged" tag would wrongly cycle ALL root ports, cutting
            # power to the debug probe alongside the target board.
            local hub_info
            hub_info=$(uhubctl_cmd -l "$uhubctl_hub" 2>/dev/null) || true
            if echo "$hub_info" | grep -E "^Current status for hub" | grep -qi "ganged"; then
                echo "Hub $uhubctl_hub uses ganged power switching — cycling all ports together" >&2
                uhubctl_port=""
            fi

            echo "Auto-detected uhubctl: hub=$uhubctl_hub port=${uhubctl_port:-all}" >&2
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

sysfs_usb_reset() {
    # On Raspberry Pi, individual USB port power control is not supported.
    # The only way to cut VBUS power is to unbind the entire internal USB
    # hub from the kernel driver, which powers off ALL USB ports at once.
    # Then rebinding restores power and triggers full re-enumeration.
    # On Pi 4 the internal hub is typically at "1-1".
    local vid=${1:-2e8a}
    local devname=""
    for dev in /sys/bus/usb/devices/*/; do
        [[ -f "$dev/idVendor" ]] || continue
        local v
        v=$(cat "$dev/idVendor" 2>/dev/null) || continue
        if [[ "$v" == "$vid" ]]; then
            devname=$(basename "$dev")
            break
        fi
    done

    if [[ -z "$devname" ]]; then
        echo "ERROR: Could not find USB device with vendor ID $vid in sysfs" >&2
        return 1
    fi

    # Walk up to the top-level port (e.g. "1-1.4.2" → "1-1")
    local top_port="$devname"
    while [[ "$top_port" == *.* ]]; do
        top_port="${top_port%.*}"
    done

    echo "Power-cycling ALL USB ports by unbinding hub $top_port (probe=$devname)..." >&2
    echo "NOTE: This will disconnect all USB devices on this bus temporarily." >&2

    # Unbind the top-level hub — this cuts VBUS power to all ports
    if [[ -e "/sys/bus/usb/drivers/usb/$top_port" ]]; then
        echo "$top_port" | sudo tee /sys/bus/usb/drivers/usb/unbind > /dev/null
        echo "Hub $top_port unbound — USB power is OFF." >&2
    else
        echo "ERROR: Hub $top_port not found in USB driver" >&2
        return 1
    fi

    sleep 5

    # Rebind the hub — this restores power and triggers re-enumeration
    echo "$top_port" | sudo tee /sys/bus/usb/drivers/usb/bind > /dev/null
    echo "Hub $top_port rebound — USB power is ON, waiting for re-enumeration..." >&2

    sleep 3

    for _wait in $(seq 1 20); do
        if ls /dev/ttyACM* >/dev/null 2>&1; then
            echo "Debug probe re-enumerated successfully." >&2
            return 0
        fi
        sleep 1
    done
    echo "WARNING: Debug probe did not re-enumerate after 20s" >&2
    return 1
}

usb_power_reset() {
    if [[ -n "$uhubctl_hub" ]] && uhubctl_cmd --version >/dev/null 2>&1; then
        local port_args=()
        if [[ -n "$uhubctl_port" ]]; then
            # $uhubctl_port may be a uhubctl port list/range (e.g. "1,2" to
            # power-cycle the debug probe and the target board together).
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
    # Fallback: sysfs authorized toggle (works without uhubctl)
    sysfs_usb_reset
}

openocd_reset_halt() {
    # Catch the CPU before it runs bad firmware after a power cycle.
    # Try normal reset halt first; if that fails, use rescue DP.
    if openocd -c "set USE_CORE 0" -f "$interface_cfg" -f "$target_cfg" \
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

openocd_mass_erase() {
    # Nuclear recovery for a wedged chip. Rescue-halt the core (so no bad
    # firmware is running), then erase ALL of flash. After this there is no
    # auto-running image left to re-wedge the QSPI into Quad I/O mode on the
    # next boot, so the following program+verify starts from a clean slate.
    # Erases the rootfs too, so callers must reflash BOTH kernel and rootfs.
    openocd_rescue_reset || true
    echo "Mass-erasing flash to recover wedged target..." >&2
    if ! openocd -c "set USE_CORE 0" -f "$interface_cfg" -f "$target_cfg" \
        -c "adapter speed 1000" \
        -c "init" -c "reset halt" \
        -c "flash erase_sector 0 0 last" \
        -c "exit" 2>&1; then
        echo "mass-erase failed" >&2
        return 1
    fi
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

    flash_ok=0
    # Programming bursts a lot of CMSIS-DAP traffic; the configured speed (often
    # 20000 kHz, fine for interactive debug) desyncs the probe under that load
    # ("CMSIS-DAP command mismatch"). Cap the FIRST program attempt at 8000 kHz;
    # on any failure drop to 4000 kHz (then lower) — a wedged QSPI / marginal SWD
    # link flashes far more reliably slow.
    flash_speed=$adapter_speed
    if (( flash_speed > 8000 )); then
        flash_speed=8000
    fi
    for flash_attempt in 1 2 3 4; do
        openocd_cmd=(
            openocd
            -c "set USE_CORE 0"
            -f "$interface_cfg"
            -f "$target_cfg"
            -c "adapter speed $flash_speed"
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

        if "${openocd_cmd[@]}"; then
            flash_ok=1
            break
        fi

        # Reduce adapter speed for the next attempt (floor 1000 kHz).
        if (( flash_speed > 4000 )); then
            flash_speed=4000
        elif (( flash_speed > 2000 )); then
            flash_speed=2000
        else
            flash_speed=1000
        fi
        echo "Flash attempt $flash_attempt failed; rescuing target and retrying at ${flash_speed}kHz..." >&2
        # Always run the rescue DP script to clear QSPI Quad I/O / double-fault
        # lockups before retrying.
        openocd_rescue_reset || true
        # From the 2nd failure on, escalate to a full USB power-cycle.
        if (( flash_attempt >= 2 )); then
            if usb_power_reset; then
                echo "USB power-cycle complete, halting target..." >&2
                openocd_reset_halt || openocd_rescue_reset
            else
                sleep 2
                openocd_rescue_reset
            fi
        fi
        # LAST-DITCH only before the final retry: mass-erase flash. This wipes
        # the whole flash chip
        # (~2 min at low SWD speed) and forces a full kernel+rootfs reflash, so
        # it must NOT run on transient link glitches (CMSIS-DAP command mismatch
        # / USB drops) — doing so amplifies a glitch into an erased, unbootable
        # board. Only reach for it after rescue-DP + speed backoff + USB
        # power-cycle have all failed, i.e. a genuinely wedged auto-running image.
        if (( flash_attempt >= 3 && flash_attempt < 4 )); then
            if openocd_mass_erase; then
                flash_kernel=1
                if [[ -n "$remote_rootfs" ]]; then
                    flash_rootfs=1
                else
                    echo "Mass erase wiped rootfs, but this run has no rootfs artifact to restore." >&2
                    echo "Re-run with a full flash (--force/--force-flash), not --force-kernel-flash." >&2
                    exit 1
                fi
            fi
        fi
    done
    if (( ! flash_ok )); then
        echo "ERROR: flashing failed after 4 attempts" >&2
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

# One numbered directory per run (logs/1, logs/2, ...), instead of a single
# logs/ wiped at the start of every run. Comparing two runs -- the whole point
# of --profile -- needs both of them to still exist, and the timing/profile
# report is written into this directory too, so an A/B is just two numbers.
# The id comes from the caller so the local side knows which directory to
# mirror and tail without having to guess.
#
# Under the work dir, NOT under the repo: sync_remote_repo_sources() rsyncs the
# repo with --delete and excludes only /workdir/, so anything the repo tree does
# not have locally -- a runs root at $remote_repo/logs included -- is deleted at
# the start of every run. That is also why the old layout could get away with
# wiping logs/ itself: it was ephemeral either way.
runs_root="$remote_work_dir/logs"
run_dir="$runs_root/$run_id"
mkdir -p "$runs_root"
rm -rf "$run_dir"
mkdir -p "$run_dir"
ln -sfn "$run_id" "$runs_root/latest"
export YASOS_TIMING_REPORT_DIR="$run_dir"
export YASOS_SMOKE_LOG_DIR="$run_dir"

# What this run *was*, so a directory found later is self-describing: the two
# arms of an A/B differ by exactly one of these lines.
{
    printf 'run_id=%s\n' "$run_id"
    printf 'started=%s\n' "$(date -Iseconds)"
    printf 'kernel_sha=%s\n' "$kernel_sha"
    printf 'rootfs_sha=%s\n' "$rootfs_sha"
    printf 'profile=%s\n' "$profile"
    printf 'opt_levels=%s\n' "$smoke_tcc_opt_level"
    printf 'gcc_torture=%s\n' "$with_gcc_torture"
    printf 'extra_tcc_cflags=%s\n' "$extra_tcc_cflags"
    printf 'tcc_env_prefix=%s\n' "$tcc_env_prefix"
    printf 'git_rev=%s\n' "$(git -C "$remote_repo" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'pytest_args=%s\n' "${*@Q}"
} > "$run_dir/run_info.txt"

# Keep the last $keep_runs runs; 0 keeps everything. Full-suite runs leave tens
# of MiB of transcripts behind, and this is a Pi.
if (( keep_runs > 0 )); then
    mapfile -t run_dirs < <(find "$runs_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | grep -E '^[0-9]+$' | sort -n)
    prune_count=$(( ${#run_dirs[@]} - keep_runs ))
    for (( i = 0; i < prune_count; i++ )); do
        rm -rf "${runs_root:?}/${run_dirs[$i]}"
    done
    if (( prune_count > 0 )); then
        echo "Pruned $prune_count old run dir(s) from $runs_root, keeping the last $keep_runs"
    fi
fi
echo "Run $run_id logging to $run_dir"

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

if [[ "${rerun_failed}" == "1" ]]; then
    export YASOS_SMOKE_RERUN_FAILED=1
fi

if [[ "${profile}" == "1" ]]; then
    export YASOS_TCC_PROFILE=1
fi

# Every suite (tests2, ir_tests, gcc-torture) iterates these, so the count of
# levels multiplies the run. Echoed because a partial-matrix run looking like a
# full one is the mistake worth catching in the log.
if [[ -n "${smoke_tcc_opt_level}" ]]; then
    export YASOS_SMOKE_TCC_OPT_LEVELS="${smoke_tcc_opt_level}"
    echo "Smoke tcc optimization levels: ${smoke_tcc_opt_level}"
fi

if [[ -n "${extra_tcc_cflags}" ]]; then
    export YASOS_EXTRA_TCC_CFLAGS="${extra_tcc_cflags}"
fi

# Prefix put in front of every on-device `tcc` invocation, e.g.
# "TCC_KEEP_FWD_DRY=1 ". This is how one firmware carries both arms of an A/B:
# the knob lives in tcc and the harness selects the arm per run.
if [[ -n "${tcc_env_prefix}" ]]; then
    export YASOS_TCC_ENV_PREFIX="${tcc_env_prefix}"
fi

# How the source manifest gets its first map. The default ("push") establishes
# the whole corpus in one batched transfer before the first compile, so an
# interrupted run leaves the device -- and the map -- in the same state a
# complete one would. "lazy" is the old behaviour: the tests verify their own
# sources and bank each one, so a map only exists after a run that reaches the
# end, and an interrupted run leaves the next one hashing every source again.
case "${seed_source_manifest}" in
    push)  export YASOS_SMOKE_SOURCE_MANIFEST_PUSH=1 ;;
    lazy)  export YASOS_SMOKE_SOURCE_MANIFEST_PUSH=0 ;;
    check) export YASOS_SMOKE_SOURCE_MANIFEST_PUSH=0
           export YASOS_SMOKE_SOURCE_MANIFEST_CHECK=1 ;;
    trust) export YASOS_SMOKE_SOURCE_MANIFEST_PUSH=0
           export YASOS_SMOKE_SOURCE_MANIFEST_TRUST=1 ;;
    off)   export YASOS_SMOKE_SOURCE_MANIFEST=0 ;;
esac

# Expose the flash artifacts so the in-test reset escalation
# (tests/smoke/reflash_target.sh, called from session.py) can reflash a board
# that neither OpenOCD reset nor a USB power-cycle could revive.
export YASOS_SMOKE_REMOTE_KERNEL="${remote_kernel}"
export YASOS_SMOKE_REMOTE_ROOTFS="${remote_rootfs}"
export YASOS_SMOKE_ROOTFS_ADDRESS="${rootfs_address}"
export YASOS_SMOKE_OPENOCD_INTERFACE_CFG="${interface_cfg}"
export YASOS_SMOKE_OPENOCD_TARGET_CFG="${target_cfg}"
export YASOS_SMOKE_OPENOCD_ADAPTER_SPEED="${adapter_speed}"

pytest_cmd=("$remote_work_dir/venv/bin/pytest" -W error -sv)
if (( test_retries > 0 )); then
    pytest_cmd+=(--reruns "$test_retries" --reruns-delay 1)
fi

# The exit status is recorded next to the logs and then re-raised, so a run
# directory says on its own whether it is a complete result or the wreckage of
# an aborted run -- which matters when it is one arm of an A/B read back later.
set +e
"${pytest_cmd[@]}" "$@"
pytest_status=$?
set -e
printf 'finished=%s\nstatus=%s\n' "$(date -Iseconds)" "$pytest_status" >> "$run_dir/run_info.txt"
exit "$pytest_status"
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
        "1" if rerun_failed else "0",
        kernel_sha,
        rootfs_sha,
        requirements_sha,
        "1" if force else "0",
        "1" if bool(config.get("profile", False)) else "0",
        str(config.get("uhubctl_hub", "")),
        str(config.get("uhubctl_port", "")),
        "1" if kernel_only else "0",
        str(config.get("smoke_tcc_opt_level", DEFAULT_CONFIG["smoke_tcc_opt_level"])),
        str(config.get("extra_tcc_cflags", "")),
        str(config.get("seed_source_manifest", "")),
        str(config.get("tcc_env_prefix", "")),
        str(run_id),
        str(keep_runs),
        *pytest_args,
    ]
    cmd = ssh_base(config) + [
        "bash", "-s", "--",
        *[shlex.quote(a) for a in remote_args],
    ]
    run_error: RunnerError | None = None
    stop_sync = threading.Event()
    sync_thread: threading.Thread | None = None
    tailer: _LogTailer | None = None
    if not flash_only:
        # Scoped to this run's directory: it does not exist yet (the remote
        # creates it after flashing), which the tailer treats as "nothing to
        # follow yet" rather than as an error.
        local_run_dir = local_smoke_logs_dir(config) / str(run_id)
        print(
            f"Run {run_id}: remote {remote_runs_root(config)}/{run_id}"
            f" -> local {local_run_dir}"
        )
        tailer = _LogTailer(
            local_run_dir,
            stream_after=float(config.get("log_stream_after", LOG_STREAM_AFTER_SECONDS)),
        )
        sync_thread = threading.Thread(
            target=_background_log_sync,
            args=(config, stop_sync, tailer),
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
            if tailer is not None:
                tailer.note_output(line)
            # The tailer prints from its own thread, so take the same lock the
            # pytest stream uses; otherwise the two interleave mid-line.
            with _STDOUT_LOCK:
                sys.stdout.write(line)
                sys.stdout.flush()
        proc.wait()
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
                fetched_logs_dir = fetch_remote_smoke_logs(config, run_id)
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


def run_remote_rescue(config: dict[str, Any]) -> None:
    """Force-recover a wedged RP2350 over the rescue debug port.

    For when ordinary flashing keeps failing: connect via the rescue DP (works
    even while the core is stuck running bad firmware / QSPI is wedged in Quad
    I/O mode), halt, then mass-erase all of flash. After this no auto-running
    image survives to re-wedge the QSPI, so a subsequent --force / --force-flash
    starts from a clean slate. The chip is left halted and erased; this wipes
    BOTH kernel and rootfs, so reflash both afterwards.
    """
    board = BOARD_PROFILES[config["board"]]
    remote_script = """set -euo pipefail
remote_repo=$1
interface_cfg=$2
target_cfg=$3

cd "$remote_repo"

echo "Rescue DP reset (force-halt the core)..." >&2
openocd -f "$interface_cfg" -f target/rp2350-rescue.cfg \
    -c "adapter speed 5000" -c "init" -c "exit" 2>&1 || true
sleep 1

echo "Mass-erasing flash at 1000 kHz (slow = reliable on a wedged QSPI)..." >&2
openocd -f "$interface_cfg" -f "$target_cfg" \
    -c "adapter speed 1000" \
    -c "init" -c "reset halt" \
    -c "flash erase_sector 0 0 last" \
    -c "exit"

echo "Flash erased; target halted. Reflash with: remote_smoke_tui.py --force" >&2
"""
    cmd = ssh_base(config) + [
        "bash",
        "-s",
        "--",
        str(config["remote_repo_path"]),
        board.interface_cfg,
        board.target_cfg,
    ]
    run_command(cmd, input_text=remote_script)


def run_remote_connect(config: dict[str, Any]) -> None:
    """Open an interactive serial console to the target over SSH.

    No build, flash, or reset — just attach to the board's UART so the user can
    drive the shell. Uses pyserial's miniterm (already a remote dependency) over
    an SSH-allocated TTY. Exit the console with Ctrl-].
    """
    serial_device = str(config.get("serial_device", "")).strip()
    baud = str(CONSOLE_BAUDRATE)
    script = f"""set -euo pipefail
serial_device={shlex.quote(serial_device)}
baud={shlex.quote(baud)}
if [[ -z "$serial_device" ]]; then
    serial_device=$(python3 -c "
import serial.tools.list_ports
for p in serial.tools.list_ports.comports(include_links=False):
    print(p.device)
    break
" 2>/dev/null || true)
fi
if [[ -z "$serial_device" ]]; then
    echo 'ERROR: No serial device found. Set serial_device in the runner config.' >&2
    exit 1
fi
echo "Connecting to $serial_device @ ${{baud}} baud. Exit with Ctrl-]" >&2
exec python3 -m serial.tools.miniterm --raw "$serial_device" "$baud"
"""
    run_remote_tty_script(config, script)


def run_remote_power_reset(config: dict[str, Any]) -> None:
    uhubctl_hub = str(config.get("uhubctl_hub", "")).strip()
    uhubctl_port = str(config.get("uhubctl_port", "")).strip()
    if not uhubctl_hub:
        # Default to auto-detect when no hub is configured
        uhubctl_hub = "auto"
    remote_script = """set -euo pipefail
uhubctl_hub=$1
uhubctl_port=$2

detect_usb_device() {
    # Find a USB device by vendor ID in sysfs
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

sysfs_usb_reset() {
    # On Raspberry Pi, individual USB port power control is not supported.
    # The only way to cut VBUS power is to unbind the entire internal USB
    # hub from the kernel driver, which powers off ALL USB ports at once.
    # Then rebinding restores power and triggers full re-enumeration.
    local vid=${1:-2e8a}
    local devname=""
    for dev in /sys/bus/usb/devices/*/; do
        [[ -f "$dev/idVendor" ]] || continue
        local v
        v=$(cat "$dev/idVendor" 2>/dev/null) || continue
        if [[ "$v" == "$vid" ]]; then
            devname=$(basename "$dev")
            break
        fi
    done

    if [[ -z "$devname" ]]; then
        echo "ERROR: Could not find USB device with vendor ID $vid in sysfs" >&2
        return 1
    fi

    # Walk up to the top-level port (e.g. "1-1.4.2" -> "1-1")
    local top_port="$devname"
    while [[ "$top_port" == *.* ]]; do
        top_port="${top_port%.*}"
    done

    echo "Power-cycling ALL USB ports by unbinding hub $top_port (probe=$devname)..."
    echo "NOTE: This will disconnect all USB devices on this bus temporarily."

    if [[ -e "/sys/bus/usb/drivers/usb/$top_port" ]]; then
        echo "$top_port" | sudo tee /sys/bus/usb/drivers/usb/unbind > /dev/null
        echo "Hub $top_port unbound — USB power is OFF."
    else
        echo "ERROR: Hub $top_port not found in USB driver" >&2
        return 1
    fi

    sleep 5

    echo "$top_port" | sudo tee /sys/bus/usb/drivers/usb/bind > /dev/null
    echo "Hub $top_port rebound — USB power is ON, waiting for re-enumeration..."

    sleep 3

    for _wait in $(seq 1 20); do
        if ls /dev/ttyACM* >/dev/null 2>&1; then
            echo "Debug probe re-enumerated successfully."
            return 0
        fi
        sleep 1
    done
    echo "WARNING: Debug probe did not re-enumerate after 20s"
    return 1
}

uhubctl_bin=$(command -v uhubctl 2>/dev/null || echo /usr/sbin/uhubctl)
use_uhubctl=0
if [[ -x "$uhubctl_bin" ]]; then
    use_uhubctl=1
fi

if [[ "$uhubctl_hub" == "auto" ]]; then
    detected=$(detect_usb_device 2e8a) || { echo "ERROR: could not auto-detect USB hub for Pico" >&2; exit 1; }
    uhubctl_hub="${detected%% *}"
    if [[ -z "$uhubctl_port" ]]; then
        uhubctl_port="${detected##* }"
    fi
    if (( use_uhubctl )); then
        # Verify uhubctl recognises this hub; walk up if not.
        if ! sudo "$uhubctl_bin" -l "$uhubctl_hub" >/dev/null 2>&1; then
            echo "Hub $uhubctl_hub not uhubctl-compatible, walking up to parent..."
            if [[ "$uhubctl_hub" == *.* ]]; then
                uhubctl_port="${uhubctl_hub##*.}"
                uhubctl_hub="${uhubctl_hub%.*}"
            else
                uhubctl_port="${uhubctl_hub#*-}"
                uhubctl_hub="${uhubctl_hub%%-*}"
            fi
        fi

        # Check for ganged power switching (e.g. RPi 4 VIA VL805 hub).
        # Per-port power control doesn't work — must cycle all ports together.
        # Match only the target hub's OWN status header, not its connected-device
        # lines: a ppps root hub may host a ganged child hub (e.g. Waveshare),
        # and matching that child's tag would cut power to the debug probe too.
        hub_info=$(sudo "$uhubctl_bin" -l "$uhubctl_hub" 2>/dev/null) || true
        if echo "$hub_info" | grep -E "^Current status for hub" | grep -qi "ganged"; then
            echo "Hub $uhubctl_hub uses ganged power switching — cycling all ports together"
            uhubctl_port=""
        fi
    fi
    echo "Auto-detected: hub=$uhubctl_hub port=${uhubctl_port:-all}"
fi

if (( use_uhubctl )); then
    port_args=()
    if [[ -n "$uhubctl_port" ]]; then
        # $uhubctl_port may be a uhubctl port list/range (e.g. "1,2" to
        # power-cycle the debug probe and the target board together).
        port_args=(-p "$uhubctl_port")
    fi

    echo "Power-cycling USB via uhubctl (hub=$uhubctl_hub port=${uhubctl_port:-all})..."
    sudo "$uhubctl_bin" -l "$uhubctl_hub" "${port_args[@]}" -a off -r 100
    sleep 3
    for _attempt in 1 2 3; do
        if sudo "$uhubctl_bin" -l "$uhubctl_hub" "${port_args[@]}" -a on -r 100 2>/dev/null; then
            break
        fi
        sleep 2
    done
    sleep 3
    echo "Power-cycle complete."
else
    echo "uhubctl not found, using sysfs USB port reset fallback..."
    sysfs_usb_reset
fi
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
    openocd_init = 'openocd -c "set USE_CORE 0" -f "$interface_cfg" -f "$target_cfg" -c "adapter speed $adapter_speed" -c "init"'
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
    "$gdb_bin" -nx "$remote_kernel"
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


def run_remote_gdb_live(
    config: dict[str, Any],
    remote_kernel: str,
    gdb_bin: str,
    target_command: str,
    gdb_script_arg: str,
    board: Any,
    adapter_speed: str,
    serial_device: str,
    local_repo_path: str,
) -> None:
    """Live GDB attach: arm breakpoints/watchpoints BEFORE user code runs.

    Flow:
      1. Rescue-DP reset, then OpenOCD ``reset halt`` leaving the GDB server up
         (target halted at the reset vector).
      2. Launch a background serial sender that opens the UART, waits for the
         shell prompt, and types *target_command* — but the board only boots
         once GDB ``continue``s, so it blocks until then.
      3. Start GDB in the foreground with the user script (which arms HW
         breakpoints / a DWT watchpoint, then ``continue``s).  The board boots,
         the sender fires the command, and the corruptor halts the core at its
         own PC.
    """
    import base64

    # Serial sender for live mode: NO target reset (GDB/OpenOCD own the core);
    # just wait for the prompt — which appears only after GDB continues — then
    # send the command and keep draining the UART into the log until killed.
    serial_live_py = f"CONSOLE_BAUDRATE = {CONSOLE_BAUDRATE}\n" + r'''
import serial
import sys
import time

serial_device = sys.argv[1]
target_command = sys.argv[2]
log_path = sys.argv[3]

PROMPT = b"$ "
BOOT_WAIT = 240  # board boots only after GDB issues `continue`

print(f"[live-serial] opening {serial_device} @{CONSOLE_BAUDRATE}; waiting for boot prompt "
      f"(GDB must `continue` the halted target)...", file=sys.stderr)
ser = serial.Serial(serial_device, CONSOLE_BAUDRATE, timeout=1)
ser.reset_input_buffer()

logf = open(log_path, "wb")
tail = b""
sent = False
start = time.time()
while True:
    chunk = ser.read(256)
    if chunk:
        logf.write(chunk)
        logf.flush()
        tail = (tail + chunk)[-256:]
        if not sent and tail.endswith(PROMPT):
            print("[live-serial] prompt seen; sending command", file=sys.stderr)
            ser.write((target_command + "\n").encode())
            sent = True
    elif not sent and time.time() - start > BOOT_WAIT:
        print("[live-serial] WARNING: no boot prompt within "
              f"{BOOT_WAIT}s; still waiting (Ctrl-C in GDB to abort)", file=sys.stderr)
        start = time.time()
'''
    serial_script_b64 = base64.b64encode(serial_live_py.encode()).decode()

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

UART_LOG=/tmp/yasos-gdb-live-uart.log
SERIAL_PY=/tmp/yasos-gdb-live-serial.py

cleanup() {{
    if [[ -n "${{serial_pid:-}}" ]]; then
        kill "$serial_pid" 2>/dev/null || true
        wait "$serial_pid" 2>/dev/null || true
    fi
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

echo "Live GDB watchpoint mode"
echo "Using serial device: $serial_device"
echo "Target command (sent after GDB continues): $target_command"

echo "{serial_script_b64}" | base64 -d > "$SERIAL_PY"

# -- Rescue DP reset to clear any overclock/fault state from a prior crash --
openocd -f "$interface_cfg" -f "target/rp2350-rescue.cfg" \\
    -c "adapter speed 5000" -c "init" -c "exit" >/tmp/yasos-openocd-rescue.log 2>&1 || true
sleep 1

# -- reset HALT with the GDB server left running (target stopped at reset) --
openocd -c "set USE_CORE 0" -f "$interface_cfg" -f "$target_cfg" \\
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

echo "OpenOCD ready (target halted at reset). Starting background serial sender..."
echo "UART log: $UART_LOG"

# Background sender waits for the prompt (which only appears after GDB continues).
python3 "$SERIAL_PY" "$serial_device" "$target_command" "$UART_LOG" &
serial_pid=$!

echo 'Starting GDB (live attach). The script arms breakpoints, then continue.'
echo "After a hit, run: yasld-load $UART_LOG   to symbolize."

gdb_args=(
    "$gdb_bin" -nx "$remote_kernel"
    -ex "source scripts/yasld_gdb.py"
    -ex "directory $remote_repo"
    -ex "target extended-remote :3333"
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


def run_remote_gdb_debug(
    config: dict[str, Any],
    remote_kernel: str,
    gdb_bin: str,
    target_command: str,
    gdb_script: str | None = None,
    live: bool = False,
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

    When *live* is True the ordering is inverted for catching faults in the act:
    GDB attaches to a reset-HALTED target FIRST (so a script can arm HW
    breakpoints / DWT watchpoints before any user code runs), then a background
    serial sender types *target_command* only AFTER the GDB script issues
    ``continue`` and the board reaches the shell prompt.  The corruptor then
    stops the core at its own PC.  The GDB script must use absolute addresses
    (yasld symbols are not loaded up front in live mode — no crash log exists
    yet; run ``yasld-load /tmp/yasos-gdb-live-uart.log`` interactively after the
    hit to symbolize).
    """
    board = BOARD_PROFILES[config["board"]]
    adapter_speed = str(config["openocd_adapter_speed"])
    serial_device = str(config.get("serial_device", "")).strip()
    local_repo_path = REPO_ROOT.as_posix()

    gdb_script_arg = ""
    if gdb_script:
        gdb_script_arg = shlex.quote(gdb_script)

    if live:
        run_remote_gdb_live(
            config,
            remote_kernel,
            gdb_bin,
            target_command=target_command,
            gdb_script_arg=gdb_script_arg,
            board=board,
            adapter_speed=adapter_speed,
            serial_device=serial_device,
            local_repo_path=local_repo_path,
        )
        return

    # Build the serial capture Python script as a separate string to avoid
    # nested triple-quote issues inside the bash f-string.
    serial_capture_py = f"CONSOLE_BAUDRATE = {CONSOLE_BAUDRATE}\n" + r'''
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

print(f"Opening {serial_device} at {CONSOLE_BAUDRATE} baud...", file=sys.stderr)
ser = serial.Serial(serial_device, CONSOLE_BAUDRATE, timeout=TIMEOUT_BOOT)
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
# Rescue DP reset first: after a phase-1 crash the core can be left in a
# faulted/overclocked state where `reset halt` alone leaves the DAP unable to
# read registers (gdb sees 'E0E' -> "program is not being run").  The rescue
# config recovers the DP so the subsequent gdb session can read regs / arm
# DWT watchpoints.
if [[ "${{YASOS_GDB_POSTMORTEM:-0}}" == "1" ]]; then
  # Post-mortem: halt the still-running (panic-looping) board WITHOUT reset, so
  # PSRAM (heap/stack) stays valid for inspection.
  openocd -c "set USE_CORE 0" -f "$interface_cfg" -f "$target_cfg" \\
      -c "adapter speed $adapter_speed" \\
      -c "init" \\
      -c "halt" >/tmp/yasos-openocd.log 2>&1 &
else
  openocd -f "$interface_cfg" -f "target/rp2350-rescue.cfg" \\
      -c "adapter speed 5000" -c "init" -c "exit" >/tmp/yasos-openocd-rescue.log 2>&1 || true
  sleep 1
  openocd -c "set USE_CORE 0" -f "$interface_cfg" -f "$target_cfg" \\
      -c "adapter speed $adapter_speed" \\
      -c "init" \\
      -c "reset halt" >/tmp/yasos-openocd.log 2>&1 &
fi
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
    "$gdb_bin" -nx "$remote_kernel"
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


def collect_smoke_tests(pytest_args: list[str], with_gcc_torture: bool, smoke_tcc_opt_level: str) -> list[str]:
    env = dict(os.environ)
    if with_gcc_torture:
        env["YASOS_SMOKE_ENABLE_GCC_TORTURE"] = "1"
    else:
        env.pop("YASOS_SMOKE_ENABLE_GCC_TORTURE", None)
    env["YASOS_SMOKE_TCC_OPT_LEVELS"] = smoke_tcc_opt_level

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
    ensure_gcc_torture_submodule(runtime_config)
    pytest_args = shlex.split(str(runtime_config["pytest_args"]).strip() or "tests/smoke")
    for nodeid in collect_smoke_tests(
        pytest_args,
        bool(runtime_config.get("with_gcc_torture", False)),
        str(runtime_config.get("smoke_tcc_opt_level", DEFAULT_CONFIG["smoke_tcc_opt_level"])),
    ):
        print(nodeid)


def apply_runtime_pytest_overrides(config: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    runtime_config = dict(config)

    if args.test_retries is not None:
        runtime_config["test_retries"] = args.test_retries

    # Deliberately runtime-only (never written to the settings cache): how
    # chatty the live log tail is depends on what is being debugged right now.
    if getattr(args, "log_stream_after", None) is not None:
        runtime_config["log_stream_after"] = max(float(args.log_stream_after), 0.0)

    if getattr(args, "keep_runs", None) is not None:
        runtime_config["keep_runs"] = max(int(args.keep_runs), 0)

    if args.with_gcc_torture is not None:
        runtime_config["with_gcc_torture"] = args.with_gcc_torture

    if args.smoke_tcc_opt_level is not None:
        runtime_config["smoke_tcc_opt_level"] = args.smoke_tcc_opt_level

    if getattr(args, "gcc_test_suite_only", False):
        runtime_config["with_gcc_torture"] = True
        runtime_config["pytest_args"] = "tests/smoke -m gcc_torture"

    if getattr(args, "profile", False):
        runtime_config["profile"] = True

    if getattr(args, "extra_tcc_cflags", None):
        runtime_config["extra_tcc_cflags"] = args.extra_tcc_cflags

    # Deliberately not persisted into the cached config: an A/B arm is a
    # property of one run, and a sticky one would silently taint later
    # baselines.
    if getattr(args, "tcc_env_prefix", None):
        runtime_config["tcc_env_prefix"] = args.tcc_env_prefix

    # Runtime-only (never cached): which bootstrap is right depends on what the
    # device holds right now -- a board whose /root/ci survived the last run vs
    # a freshly wiped card vs QEMU, which starts with no sources at all.
    if getattr(args, "seed_source_manifest", None):
        runtime_config["seed_source_manifest"] = args.seed_source_manifest

    if args.pytest_args:
        runtime_config["pytest_args"] = str(args.pytest_args)
    elif args.tests:
        runtime_config["pytest_args"] = " ".join(shlex.quote(test) for test in args.tests)

    if getattr(args, "keyword", None):
        existing = str(runtime_config.get("pytest_args", "")).strip()
        runtime_config["pytest_args"] = f"{existing} -k {shlex.quote(args.keyword)}".strip()

    if args.log_cli_level:
        existing = str(runtime_config.get("pytest_args", "")).strip()
        runtime_config["pytest_args"] = f"{existing} --log-cli-level={shlex.quote(args.log_cli_level)}"

    if getattr(args, "rerun_failed", False):
        existing = str(runtime_config.get("pytest_args", "")).strip()
        existing_args = shlex.split(existing) if existing else []
        if "--lf" not in existing_args and "--last-failed" not in existing_args:
            runtime_config["pytest_args"] = f"{existing} --lf --lfnf=none".strip()

    return runtime_config


SMOKE_TCC_OPT_LEVEL_FLAGS = ("--smoke-tcc-opt-levels", "--smoke-tcc-opt-level")
# Deliberately looser than normalize_smoke_tcc_opt_levels(): this decides what
# the flag *consumes*, so an unsupported-but-level-shaped "-O9" has to be taken
# as the flag's value and rejected by the type function with a message naming
# the levels, rather than left behind as an unknown option.
_OPT_LEVEL_SHAPED = re.compile(r"(?i)^(?:all|-O\w+|O\d+|\d+)$")


def _is_opt_level_shaped(token: str) -> bool:
    pieces = [piece for piece in re.split(r"[\s,]+", token.strip()) if piece]
    return bool(pieces) and all(_OPT_LEVEL_SHAPED.fullmatch(piece) for piece in pieces)


def smoke_tcc_opt_levels_argument(value: str) -> str:
    """argparse ``type`` for the -O level flag.

    Raises ArgumentTypeError rather than ValueError: argparse prints the former
    verbatim, so a typo gets the message naming the supported levels instead of
    a bare "invalid value".
    """
    try:
        levels = normalize_smoke_tcc_opt_levels(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    if not levels:
        raise argparse.ArgumentTypeError("no optimization level given")
    return levels


def fold_smoke_tcc_opt_level_args(argv: list[str]) -> list[str]:
    """Rewrite ``--smoke-tcc-opt-levels -O0 -O1`` into the ``=`` form.

    argparse classifies any ``-O1``-looking token as an option rather than a
    value, so the space-separated spelling -- the one the README has always
    documented -- dies with "expected one argument", and only
    ``--smoke-tcc-opt-levels=-O1`` gets through. Folding the levels that follow
    the flag into one ``=`` argument before argparse sees them makes both
    spellings work, and lets several levels be listed without quoting.
    """
    folded: list[str] = []
    index = 0
    while index < len(argv):
        token = argv[index]
        if token not in SMOKE_TCC_OPT_LEVEL_FLAGS:
            folded.append(token)
            index += 1
            continue

        index += 1
        levels: list[str] = []
        # Only tokens that are entirely -O levels are absorbed, so the next flag
        # (or a value meant for something else) ends the run.
        while index < len(argv) and _is_opt_level_shaped(argv[index]):
            levels.append(argv[index])
            index += 1
        # With nothing to absorb, hand the bare flag to argparse so it reports
        # the missing value itself.
        folded.append(f"--smoke-tcc-opt-levels={' '.join(levels)}" if levels else "--smoke-tcc-opt-levels")
    return folded


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build YasOS locally and run smoke tests on a remote board host.")
    parser.add_argument("--run-cached", action="store_true", help="Run immediately using cached settings without opening the TUI. This is now the default when a cache file exists.")
    parser.add_argument("--reconfigure", "--configure", dest="reconfigure", action="store_true", help="Open the TUI and update cached settings before running.")
    parser.add_argument("--debug", action="store_true", help="Build the kernel with Zig Debug optimization and pass --debug to build_rootfs.sh.")
    parser.add_argument("--force", action="store_true", help="Force a clean rootfs rebuild, refresh the remote smoke venv, and reflash kernel/rootfs even if hashes match.")
    parser.add_argument("--gdb", action="store_true", help="Build locally, sync debug artifacts to the remote repository, then start an interactive remote GDB attach session over SSH without flashing. Combine with --reset to reset-halt before attaching.")
    parser.add_argument("--flash-only", action="store_true", help="Upload and flash artifacts on the remote host, then stop without running pytest.")
    parser.add_argument("--reset", action="store_true", help="Reset the configured target through OpenOCD on the remote host before exiting, or reset-halt before attaching when combined with --gdb.")
    parser.add_argument("--rescue", action="store_true", help="Force-recover a wedged RP2350: connect via the rescue debug port, halt, and mass-erase all flash so no auto-running image can re-wedge the QSPI. Use when flashing keeps failing. Wipes kernel AND rootfs; reflash both with --force afterwards.")
    parser.add_argument("--connect", action="store_true", help="Open an interactive serial console to the target over SSH (no build, flash, or reset). Exit the console with Ctrl-].")
    parser.add_argument("--power-reset", nargs="?", const="auto", default=None, metavar="HUB", help="Power-cycle the target via uhubctl on the remote host. Pass 'auto' (default) to detect the hub from the debug probe, or a hub path like '1-1'. Useful when the target is hung and OpenOCD cannot connect.")
    parser.add_argument("--power-reset-port", default=None, metavar="PORTS", help="Override which hub port(s) the power-cycle reset switches, as a uhubctl spec (e.g. '1,2' for the debug probe on port 1 plus the target board on port 2, or '1-2'). Defaults to the configured uhubctl port(s); empty means auto-detect the probe's port.")
    parser.add_argument("--test-retries", type=int, help="Retry failing smoke tests this many times. Uses pytest reruns for transient UART noise.")
    parser.add_argument("--log-stream-after", type=float, default=None, metavar="SECONDS", help=f"Start streaming the in-flight test's target log once it has been running this long (default {LOG_STREAM_AFTER_SECONDS:g}s). The log is rsynced from the remote host while the test runs, so a stuck test's serial transcript is visible before it times out. 0 disables streaming and only reports newly fetched log files.")
    parser.add_argument("--keep-runs", type=int, default=None, metavar="N", help=f"How many numbered run directories to keep on the remote host (default {DEFAULT_CONFIG['keep_runs']}; 0 keeps all). Every run writes its logs and its timing/profile report to logs/<N>/, so two runs can be compared afterwards; the local mirror under .cache/remote_smoke_logs is never pruned.")
    parser.add_argument("--rerun-failed", action="store_true", help="Run only tests that failed in the previous remote pytest run by passing --lf to pytest. If no last-failed cache exists on the remote host, runs no tests instead of the full suite.")
    parser.add_argument("--with-gcc-torture", dest="with_gcc_torture", action="store_true", default=None, help="Enable GCC torture smoke tests for this run. Also syncs libs/tinycc/tests/gcctestsuite and exports YASOS_SMOKE_ENABLE_GCC_TORTURE=1 remotely.")
    parser.add_argument("--smoke-tcc-opt-levels", "--smoke-tcc-opt-level", dest="smoke_tcc_opt_level", type=smoke_tcc_opt_levels_argument, metavar="LEVELS", help=f"tcc -O levels the smoke suites run at (default '{SMOKE_TCC_ALL_OPT_LEVELS}', i.e. every suite -- tests2, ir_tests and gcc-torture -- runs once per level). Pass one level for a focused, roughly 3x shorter run, or any subset: --smoke-tcc-opt-levels -O1, --smoke-tcc-opt-levels '-O0 -O2', --smoke-tcc-opt-levels all.")
    parser.add_argument("--gcc-test-suite-only", action="store_true", help="Run only GCC torture tests. Implies --with-gcc-torture and filters pytest to -m gcc_torture.")
    parser.add_argument("--extra-tcc-cflags", help="Extra CFLAGS passed to every TCC compilation during smoke tests. Example: --extra-tcc-cflags='-O1'.")
    parser.add_argument("--tcc-env-prefix", help="Environment prefix put in front of every on-device tcc invocation, so one firmware can carry both arms of an A/B. Example: --tcc-env-prefix='TCC_KEEP_FWD_DRY=1 '.")
    parser.add_argument("--seed-source-manifest", choices=("lazy", "push", "check", "trust", "off"), default=None, help="How the smoke source manifest gets its first map, when the remote .cache has none that still covers the corpus. 'push' (default) uploads whatever the device is not already witnessed to hold in one batched zmodem session (the whole 4.13 MiB corpus on a cold target) and seeds from what it just wrote -- the only mode that also works on a fresh SD card or QEMU, and the only one whose map survives an interrupted run. 'lazy' lets each test verify its own sources and banks them, so a complete map needs one run that reaches the end. 'check' uploads the 511 KiB map of hashes instead and has the device verify it with one sha256sum -c. 'trust' seeds the host map with no device work at all -- only for a board known to hold the current sources, since a device copy that exists but differs would be compiled as-is. 'off' disables the manifest entirely.")
    parser.add_argument("--pytest-args", help="Override cached pytest arguments for this run only. Example: --pytest-args 'tests/smoke -k shell_test'.")
    parser.add_argument("--tests", nargs="+", help="Run an explicit list of pytest paths or nodeids for this run only.")
    parser.add_argument("-k", dest="keyword", metavar="EXPRESSION", help="Pytest -k keyword expression to filter tests for this run, like run_qemu_smoke.sh. Appended to the effective pytest args, so it composes with --tests and --pytest-args. Example: -k 00_assignment.")
    parser.add_argument("--gdb-debug", action="store_true", help="Automated GDB debug: reset target, run a command via serial, capture yasld log, reset-halt, start GDB with symbols loaded. Requires --cmd.")
    parser.add_argument("--cmd", help="Target command to execute over serial before GDB attach (used with --gdb-debug). Example: --cmd 'tcc 15_recursion.c'")
    parser.add_argument("--gdb-script", help="Path to a GDB script file to source after connecting and loading symbols (used with --gdb-debug).")
    parser.add_argument("--gdb-live", action="store_true", help="Live variant of --gdb-debug: attach GDB to a reset-HALTED target FIRST so the --gdb-script can arm HW breakpoints / DWT watchpoints before user code runs, then a background serial sender types --cmd after the script issues `continue`. Catches faults at the corruptor's own PC. Requires --gdb-debug, --cmd and --gdb-script.")
    parser.add_argument("--log-cli-level", help="Set pytest --log-cli-level for this run (e.g. INFO, DEBUG, WARNING). Passed through to the remote pytest invocation.")
    parser.add_argument("--profile", action="store_true", help="Enable TCC performance profiling. Captures per-phase bench breakdown and per-syscall cycle counts from the kernel. Results are saved alongside the timing report.")
    parser.add_argument("--force-flash", action="store_true", help="Upload and flash existing kernel/rootfs artifacts without rebuilding. Forces reflash even if remote hashes match.")
    parser.add_argument("--force-kernel-flash", action="store_true", help="Upload and flash only the kernel artifact without rebuilding. Skips rootfs entirely.")
    parser.add_argument("--list-boards", action="store_true", help="Print supported board identifiers and exit.")
    parser.add_argument("--list-tests", action="store_true", help="Print available pytest nodeids for the smoke suite and exit. Honors --tests, --pytest-args, -k, and --with-gcc-torture.")
    return parser.parse_args(fold_smoke_tcc_opt_level_args(sys.argv[1:]))


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
        if args.gdb_live and not args.gdb_debug:
            raise RunnerError("--gdb-live requires --gdb-debug")
        if args.gdb_live and not args.gdb_script:
            raise RunnerError("--gdb-live requires --gdb-script (the script that arms the watchpoint)")

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

        if args.connect:
            print("Opening interactive serial console to the target (Ctrl-] to exit).")
            run_remote_connect(config)
            return 0

        # A changed defconfig must regenerate config/target/.config AND force a
        # full rebuild — otherwise the build silently reuses a stale generated
        # config (e.g. an old CPU clock) and the flashed firmware does not match
        # the defconfig that was edited.
        board = BOARD_PROFILES[config["board"]]
        if not _defconfig_is_up_to_date(board.defconfig):
            if not apply_defconfig or not args.force:
                print(
                    f"defconfig {board.defconfig} changed since last build "
                    "(or no record) — regenerating .config and forcing a full rebuild."
                )
            apply_defconfig = True
            args.force = True

        runtime_config = apply_runtime_pytest_overrides(config, args)
        runtime_config["remote_repo_path"] = prepare_remote_repo_path(config)

        if args.power_reset is not None:
            hub_override = args.power_reset  # 'auto' or explicit hub path
            runtime_config["uhubctl_hub"] = hub_override
            if args.power_reset_port is not None:
                runtime_config["uhubctl_port"] = normalize_uhubctl_ports(args.power_reset_port)
            port_spec = runtime_config.get("uhubctl_port") or "auto"
            print(f"Running remote USB power-cycle reset (hub={hub_override} port={port_spec}).")
            run_remote_power_reset(runtime_config)
            print("Remote power-cycle reset completed successfully.")
            return 0

        if args.rescue:
            print("Running RP2350 rescue: rescue-DP halt + flash mass-erase.")
            run_remote_rescue(runtime_config)
            print("Rescue completed. Flash erased — reflash both kernel and "
                  "rootfs with --force.")
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
                rerun_failed=args.rerun_failed,
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
                rerun_failed=args.rerun_failed,
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
                live=args.gdb_live,
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
            rerun_failed=args.rerun_failed,
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
