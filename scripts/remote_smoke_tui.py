#!/usr/bin/env python3

from __future__ import annotations

import argparse
import curses
import importlib.util
import json
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
CACHE_PATH = REPO_ROOT / ".cache" / "remote_smoke_runner.json"
KERNEL_ARTIFACT = REPO_ROOT / "zig-out" / "bin" / "yasos_kernel"
ROOTFS_ARTIFACT = REPO_ROOT / "rootfs.img"


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
    "pytest_args": "tests/smoke",
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
            ("Pytest args", "pytest_args"),
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
                continue
            if key == curses.KEY_RIGHT:
                selected_key = fields[selected][1]
                if selected_key == "board":
                    config[selected_key] = board_key_from_label(
                        cycle_option([profile.label for profile in BOARD_PROFILES.values()], board_label(str(config[selected_key])), 1)
                    )
                elif selected_key == "optimize":
                    config[selected_key] = cycle_option(OPTIMIZE_OPTIONS, str(config[selected_key]), 1)
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
                edited = edit_value(stdscr, label, str(config[selected_key]))
                if selected_key in ("ssh_port", "openocd_adapter_speed"):
                    config[selected_key] = edited.strip() or ("22" if selected_key == "ssh_port" else "20000")
                else:
                    config[selected_key] = edited

    curses.wrapper(_inner)
    return result


def command_string(cmd: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in cmd)


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
        "--files-from=-",
        "-e",
        command_string(ssh_cmd),
        "./",
        remote_dest,
    ]
    run_command(rsync_cmd, cwd=REPO_ROOT, input_text="\n".join(rel_paths) + "\n")
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
    paths = ["tests/smoke"]
    pytest_args = shlex.split(str(config["pytest_args"]).strip() or "tests/smoke")
    for arg in pytest_args:
        if arg.startswith("-"):
            continue
        candidate = REPO_ROOT / arg
        if candidate.exists():
            paths.append(arg)
    return sorted(set(paths))


def sync_smoke_support(config: dict[str, Any]) -> None:
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


def build_local_artifacts(config: dict[str, Any], debug: bool = False, build_rootfs: bool = True) -> None:
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
    run_command(
        ["zig", "build", f"-Doptimize={effective_optimize(config, debug)}"],
        cwd=REPO_ROOT,
    )
    rootfs_cmd = ["./build_rootfs.sh", "-c", "-o", ROOTFS_ARTIFACT.name]
    if build_rootfs:
        if debug:
            rootfs_cmd.append("--debug")
        run_command(rootfs_cmd, cwd=REPO_ROOT)

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


def run_remote_smoke(config: dict[str, Any], remote_work_dir: str, remote_kernel: str, remote_rootfs: str, flash_only: bool) -> None:
    board = BOARD_PROFILES[config["board"]]
    adapter_speed = str(config["openocd_adapter_speed"])
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
shift 10

mkdir -p "$remote_work_dir"

openocd -f "$interface_cfg" -f "$target_cfg" -c "adapter speed $adapter_speed" -c "program $remote_rootfs $rootfs_address" -c "program $remote_kernel verify reset exit"

if [[ "$flash_only" == "1" ]]; then
    exit 0
fi

cd "$remote_repo"

if [[ ! -x "$remote_work_dir/venv/bin/python3" ]]; then
    python3 -m venv "$remote_work_dir/venv"
fi

"$remote_work_dir/venv/bin/pip" install -r tests/smoke/requirements.txt

if [[ -n "$serial_device" ]]; then
  export SERIAL_DEVICE="$serial_device"
fi

"$remote_work_dir/venv/bin/pytest" -W error -s "$@"
"""
    cmd = ssh_base(config) + [
        "bash",
        "-s",
        "--",
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
        *pytest_args,
    ]
    run_command(cmd, input_text=remote_script)


def run_remote_reset(config: dict[str, Any]) -> None:
    board = BOARD_PROFILES[config["board"]]
    adapter_speed = str(config["openocd_adapter_speed"])
    remote_script = """set -euo pipefail
remote_repo=$1
interface_cfg=$2
target_cfg=$3
adapter_speed=$4

cd "$remote_repo"

openocd -f "$interface_cfg" -f "$target_cfg" -c "adapter speed $adapter_speed" -c "init" -c "reset run" -c "exit"
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


def run_remote_gdb(config: dict[str, Any], remote_kernel: str, gdb_bin: str, reset_before_connect: bool) -> None:
    board = BOARD_PROFILES[config["board"]]
    adapter_speed = str(config["openocd_adapter_speed"])
    openocd_init = 'openocd -f "$interface_cfg" -f "$target_cfg" -c "adapter speed $adapter_speed" -c "init"'
    if reset_before_connect:
        openocd_init += ' -c "reset halt"'
    remote_script = f"""set -euo pipefail
remote_repo={shlex.quote(str(config["remote_repo_path"]))}
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

"$gdb_bin" "$remote_kernel" \
    -ex "source scripts/yasld_gdb.py" \
    -ex "target extended-remote :3333"
"""
    run_remote_tty_script(config, remote_script)


def list_boards() -> None:
    for profile in BOARD_PROFILES.values():
        print(f"{profile.key}: {profile.label}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build YasOS locally and run smoke tests on a remote board host.")
    parser.add_argument("--run-cached", action="store_true", help="Run immediately using cached settings without opening the TUI.")
    parser.add_argument("--configure", action="store_true", help="Open the TUI even if a cache file already exists.")
    parser.add_argument("--debug", action="store_true", help="Build the kernel with Zig Debug optimization and pass --debug to build_rootfs.sh.")
    parser.add_argument("--gdb", action="store_true", help="Build locally, sync debug artifacts to the remote repository, then start an interactive remote GDB attach session over SSH without flashing. Combine with --reset to reset-halt before attaching.")
    parser.add_argument("--flash-only", action="store_true", help="Upload and flash artifacts on the remote host, then stop without running pytest.")
    parser.add_argument("--reset", action="store_true", help="Reset the configured target through OpenOCD on the remote host before exiting, or reset-halt before attaching when combined with --gdb.")
    parser.add_argument("--list-boards", action="store_true", help="Print supported board identifiers and exit.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.list_boards:
        list_boards()
        return 0

    try:
        cached = load_cache()
        if args.flash_only and args.gdb:
            raise RunnerError("--flash-only and --gdb cannot be used together")
        if args.run_cached:
            config = validate_config(cached)
            save_cache(config)
        else:
            config = run_tui(cached if args.configure or CACHE_PATH.exists() else dict(DEFAULT_CONFIG))
            if config is None:
                return 1
            config = validate_config(config)
            save_cache(config)

        runtime_config = dict(config)
        runtime_config["remote_repo_path"] = prepare_remote_repo_path(config)

        if args.reset and not args.gdb:
            print("Running remote OpenOCD reset with cached configuration.")
            run_remote_reset(runtime_config)
            print("Remote reset completed successfully.")
            return 0

        if args.gdb:
            print("Detecting remote debug tools.")
            gdb_bin = detect_remote_debug_tools(runtime_config)
            print(f"Using remote GDB binary: {gdb_bin}")
            if args.reset:
                print("Running remote GDB attach workflow with reset-before-connect.")
            else:
                print("Running remote GDB attach workflow with synced kernel symbols.")
            build_local_artifacts(runtime_config, debug=args.debug, build_rootfs=False)
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
        build_local_artifacts(runtime_config, debug=args.debug)
        remote_work_dir, remote_kernel, remote_rootfs = upload_artifacts(runtime_config)
        if not args.flash_only:
            print("Syncing smoke test files to the remote repository with rsync.")
            sync_smoke_support(runtime_config)
        run_remote_smoke(runtime_config, remote_work_dir, remote_kernel, remote_rootfs, flash_only=args.flash_only)
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