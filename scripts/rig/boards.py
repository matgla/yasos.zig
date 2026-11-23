#!/usr/bin/env python3
"""Boards on a rig: which probe belongs to which board, who may use it, and its lock.

One Pi can carry several boards, each on its own Debug Probe (the CI rig tower has
lanes A and B, hardware/ci_rig/).  Every job that touches a board -- the CI hardware
jobs, scripts/remote_smoke_tui.py, the scripts/rig/ wrappers -- takes that board
through this tool, so it holds the board's lock and talks only to that board's probe
and UART:

    boards.py scan                         probes on the bus, registered or not
    boards.py register a --pool ci --pool dev --note "lane A"
    boards.py register b --pool ci --pool dev   (the only unregistered probe is taken)
    boards.py list                         boards, their probes, who holds each
    boards.py reserve b [--hours 24]       b leaves pool ci; your `auto` runs take it
    boards.py release b                    CI may use it again
    boards.py run --pool ci -- make ...    the first free board of a pool
    boards.py run --board b -- CMD         that board, waiting while it is busy
    boards.py env b                        its environment, as shell exports
    boards.py install                      yasos-board in ~/.local/bin, for checkouts
                                           of other repositories (matgla/tinycc)

`run` takes the board's flock and execs CMD with the lock still held (CMD inherits the
descriptor, the lock goes when the last process holding it exits) and with:

    YASOS_BOARD          the board's name
    YASOS_BOARD_TYPE     its board profile (remote_smoke_tui.py BOARD_PROFILES)
    YASOS_PROBE_SERIAL   its Debug Probe's USB serial number
    SERIAL_DEVICE        its UART (/dev/serial/by-id/...), when the probe is attached
    OPENOCD_SCRIPTS      scripts/rig/openocd: an interface/cmsis-dap.cfg that selects
                         YASOS_PROBE_SERIAL, so plain `openocd -f interface/cmsis-dap.cfg`
                         reaches this board's probe and no other
    YASOS_POWER_PORTS    uhubctl "hub:port" pairs that power-cycle this board
    YASOS_BOARD_STATE    a directory for what the board holds: the flashed images'
                         hashes (kernel.sha256, rootfs.sha256), which let a job skip
                         a flash.  Only jobs run with --keeps-state keep them true
                         (remote_smoke_tui.py, scripts/rig/); any other job (CI,
                         a manual openocd) may flash, so taking the board without
                         --keeps-state deletes them and the next job flashes
    YASOS_BOARD_LOCK     the lock's path; YASOS_BOARD_LOCK_HELD marks it as held, so a
                         nested `run` for the same board does not wait on itself

Pools say who may use a board: CI jobs ask for `--pool ci`, personal work for
`--pool dev` (the default of `--board auto`).  A board can be in both.  Within a pool
boards with fewer pools come first, so personal work lands on a dedicated board and
falls back to a shared one only while the dedicated one is busy.  Among equals, `ci`
tries boards in registry order and every other pool in reverse, so with two shared
boards CI and personal work start on different ones.

A reservation (`reserve NAME`) takes a board out of every pool but `dev` until it is
released or expires (24 h by default, `--hours 0` = until released): CI stops picking
it, a job already running on it finishes, and `dev` picks it before any other board.
A board named explicitly (`--board NAME`, $YASOS_BOARD) is taken reserved or not.

The registry is ~/.config/yasos-rig/boards.json (YASOS_RIG_BOARDS overrides it).  With
no registry, `run` keeps the old single-board behaviour: the legacy lock
/var/lock/rp2350-board.lock and no probe selection.  Register the board CI shares with
matgla/tinycc's metrics job with `--lock /var/lock/rp2350-board.lock`, the lock that
job takes.
"""
from __future__ import annotations

import argparse
import fcntl
import getpass
import glob
import json
import os
import re
import shlex
import socket
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
OPENOCD_DIR = HERE / "openocd"
LEGACY_LOCK = os.environ.get("YASOS_RIG_LEGACY_LOCK", "/var/lock/rp2350-board.lock")
LOCK_DIR = os.environ.get("YASOS_RIG_LOCK_DIR", "/var/lock")
DEFAULT_TYPE = "pimoroni_pico_plus2_and_vga"
# Raspberry Pi Debug Probe (CMSIS-DAP firmware).
PROBE_IDS = {("2e8a", "000c")}
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
EXIT_BUSY = 99


class BoardError(RuntimeError):
    pass


def registry_path() -> Path:
    override = os.environ.get("YASOS_RIG_BOARDS", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / ".config" / "yasos-rig" / "boards.json"


def state_root() -> Path:
    override = os.environ.get("YASOS_RIG_STATE", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / ".local" / "state" / "yasos-rig"


def load_registry() -> dict | None:
    path = registry_path()
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BoardError(f"cannot read the board registry {path}: {error}") from error
    boards = data.get("boards")
    if not isinstance(boards, dict):
        raise BoardError(f"{path}: no \"boards\" object")
    return data


def save_registry(data: dict) -> None:
    path = registry_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def boards_of(data: dict | None) -> dict[str, dict]:
    return {} if data is None else data["boards"]


def reservation(board: dict, now: float | None = None) -> dict | None:
    """The board's reservation while it lasts, else None."""
    held = board.get("reserved")
    if not isinstance(held, dict):
        return None
    until = float(held.get("until") or 0)
    if until and (time.time() if now is None else now) >= until:
        return None
    return held


# --- USB --------------------------------------------------------------------

def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="ascii", errors="replace").strip()
    except OSError:
        return ""


def sysfs_root() -> Path:
    return Path(os.environ.get("YASOS_RIG_SYSFS", "/sys")) / "bus" / "usb" / "devices"


def attached_probes() -> dict[str, dict]:
    """Debug Probes on the bus by serial number: sysfs name, uhubctl location, tty."""
    found: dict[str, dict] = {}
    root = sysfs_root()
    if not root.is_dir():
        return found
    for dev in sorted(root.iterdir()):
        if ":" in dev.name:
            continue  # an interface, not a device
        ids = (_read(dev / "idVendor"), _read(dev / "idProduct"))
        if ids not in PROBE_IDS:
            continue
        serial = _read(dev / "serial")
        if not serial:
            continue
        found[serial] = {
            "sysfs": dev.name,
            "port": uhubctl_location(dev.name),
            "tty": probe_tty(serial, dev),
        }
    return found


def uhubctl_location(devname: str) -> str:
    """The uhubctl "hub:port" a USB device hangs off: 3-1.2 -> 3-1:2, 3-1 -> 3:1."""
    if "." in devname:
        hub, port = devname.rsplit(".", 1)
    else:
        hub, port = devname.split("-", 1)
    return f"{hub}:{port}"


def probe_tty(serial: str, dev: Path | None = None) -> str:
    """The probe's UART: its stable /dev/serial/by-id link, else the /dev node."""
    by_id = os.environ.get("YASOS_RIG_SERIAL_BY_ID", "/dev/serial/by-id")
    links = sorted(glob.glob(os.path.join(by_id, f"*_{glob.escape(serial)}-if*")))
    if links:
        return links[0]
    if dev is not None:
        for tty in sorted(dev.glob(f"{dev.name}:*/tty/*")):
            return f"/dev/{tty.name}"
    return ""


# --- locks ------------------------------------------------------------------

def lock_path(name: str, board: dict) -> str:
    return board.get("lock") or os.path.join(LOCK_DIR, f"yasos-board-{name}.lock")


def _open_lock(path: str) -> int:
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o666)
    except OSError as error:
        raise BoardError(f"cannot open the lock {path}: {error.strerror} "
                         f"(YASOS_RIG_LOCK_DIR moves the default locks)") from error
    try:
        os.fchmod(fd, 0o666)  # several users (two runner services, a login) share it
    except OSError:
        pass
    return fd


def try_lock(path: str) -> int | None:
    fd = _open_lock(path)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def holder_path(lock: str) -> str:
    return lock + ".holder"


def write_holder(lock: str, name: str, what: str) -> None:
    info = {
        "board": name,
        "pid": os.getpid(),
        "user": getpass.getuser(),
        "host": socket.gethostname(),
        "what": what,
        "since": int(time.time()),
    }
    try:
        fd = os.open(holder_path(lock), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o666)
        with os.fdopen(fd, "w") as handle:
            json.dump(info, handle)
    except OSError:
        pass  # only informational


def read_holder(lock: str) -> dict | None:
    try:
        return json.loads(Path(holder_path(lock)).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def lock_state(lock: str) -> str:
    """'free', or who holds it: "busy: <what> (pid N, user, 12m)"."""
    if not os.path.exists(lock):
        return "free"
    fd = try_lock(lock)
    if fd is not None:
        os.close(fd)
        return "free"
    holder = read_holder(lock)
    if not holder or not _pid_alive(int(holder.get("pid", 0))):
        return "busy (holder unknown: a tool that takes the lock without boards.py)"
    age = max(0, int(time.time()) - int(holder.get("since", 0)))
    return (f"busy: {holder.get('what') or 'job'} "
            f"(pid {holder.get('pid')}, {holder.get('user')}, {_age(age)})")


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _age(seconds: int) -> str:
    if seconds < 120:
        return f"{seconds}s"
    if seconds < 7200:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}m"


# --- selection --------------------------------------------------------------

def board_env(name: str, board: dict, probes: dict[str, dict], count: int) -> dict[str, str]:
    serial = board.get("probe", "")
    attached = probes.get(serial, {})
    tty = attached.get("tty") or (probe_tty(serial) if serial else "")
    state = state_root() / "boards" / name
    state.mkdir(parents=True, exist_ok=True)
    env = {
        "YASOS_BOARD": name,
        "YASOS_BOARD_TYPE": board.get("type", DEFAULT_TYPE),
        "YASOS_PROBE_SERIAL": serial,
        "OPENOCD_SCRIPTS": str(OPENOCD_DIR),
        "YASOS_POWER_PORTS": " ".join(board.get("power") or ([attached["port"]] if attached else [])),
        "YASOS_BOARD_STATE": str(state),
        "YASOS_BOARD_LOCK": lock_path(name, board),
        "YASOS_RIG_BOARD_COUNT": str(count),
    }
    if tty:
        env["SERIAL_DEVICE"] = tty
    return env


def candidates(boards: dict[str, dict], board: str | None, pool: str,
               board_type: str | None = None) -> list[str]:
    """Board names to try, in order.  An explicit name is the only candidate."""
    def type_of(name: str) -> str:
        return boards[name].get("type", DEFAULT_TYPE)

    if board and board != "auto":
        if board not in boards:
            known = ", ".join(boards) or "none registered"
            raise BoardError(f"no board '{board}' in {registry_path()} ({known})")
        if board_type and type_of(board) != board_type:
            raise BoardError(f"board '{board}' is a {type_of(board)}, not a {board_type}")
        return [board]
    order = list(boards)
    names = [n for n in order if pool in (boards[n].get("pools") or [])
             and (not board_type or type_of(n) == board_type)]
    if not names:
        what = f"pool '{pool}'" + (f" of type {board_type}" if board_type else "")
        raise BoardError(f"no board in {what} ({registry_path()})")
    if pool != "dev":
        # Reserved boards are personal work's until released.
        free = [n for n in names if reservation(boards[n]) is None]
        if not free:
            raise BoardBusy(f"every board of pool '{pool}' is reserved: "
                            + ", ".join(names) + " (boards.py release NAME)")
        names = free
    # Reserved boards first (dev only has them now), then dedicated ones: personal
    # work goes to the board that is only its own and to a board it shares with CI
    # only while that one is busy.  Ties: CI in registry order, the rest reversed.
    step = 1 if pool == "ci" else -1
    names.sort(key=lambda n: (reservation(boards[n]) is None,
                              len(boards[n].get("pools") or []), step * order.index(n)))
    return names


def acquire(pick, wait: float, what: str,
            quiet: bool = False) -> tuple[dict[str, dict], str, int | None]:
    """Lock the first free board pick() names, waiting up to wait seconds.

    pick() returns (boards, names) and runs again every round, so a board
    reserved or released while this waits counts.  Returns the boards, the
    board and the locked descriptor (None when this process tree already holds
    the board's lock, YASOS_BOARD_LOCK_HELD)."""
    boards, names = pick()
    held = os.environ.get("YASOS_BOARD_LOCK_HELD", "")
    for name in names:
        if held and held == lock_path(name, boards[name]):
            return boards, name, None
    deadline = time.monotonic() + max(0.0, wait)
    announced = False
    parent = os.getppid()
    first = True
    while True:
        if os.getppid() != parent:
            # Whoever asked is gone (an ssh session closed while we queued, which
            # signals nothing without a tty): do not take the board for nobody.
            raise BoardBusy("the caller went away while waiting")
        if not first:
            boards, names = pick()
        first = False
        for name in names:
            lock = lock_path(name, boards[name])
            fd = try_lock(lock)
            if fd is not None:
                write_holder(lock, name, what)
                if announced and not quiet:
                    log(f"got board {name}")
                return boards, name, fd
        states = ("every board of the pool is reserved" if not names else
                  "; ".join(f"{n}: {lock_state(lock_path(n, boards[n]))}" for n in names))
        if time.monotonic() >= deadline:
            raise BoardBusy(f"no free board after {int(wait)} s ({states})")
        if not announced and not quiet:
            log(f"waiting up to {int(wait)} s for a board -- {states}")
            announced = True
        time.sleep(2.0)


class BoardBusy(BoardError):
    pass


def log(text: str) -> None:
    print(f"boards: {text}", file=sys.stderr, flush=True)


# --- commands ---------------------------------------------------------------

def cmd_scan(args: argparse.Namespace) -> int:
    boards = boards_of(load_registry())
    by_serial = {b.get("probe"): n for n, b in boards.items()}
    probes = attached_probes()
    if args.json:
        print(json.dumps({s: dict(p, board=by_serial.get(s)) for s, p in probes.items()}, indent=2))
        return 0
    if not probes:
        print("no Debug Probe on the bus")
        return 0
    for serial, probe in probes.items():
        board = by_serial.get(serial)
        print(f"{serial}  usb {probe['sysfs']:<8} power {probe['port']:<8} "
              f"{probe['tty'] or '(no tty)'}  {'board ' + board if board else 'unregistered'}")
    return 0


def cmd_register(args: argparse.Namespace) -> int:
    if not NAME_RE.match(args.name):
        raise BoardError(f"board names are [a-z0-9_-], up to 32 characters: '{args.name}'")
    data = load_registry() or {"version": 1, "boards": {}}
    boards = data["boards"]
    existing = boards.get(args.name)
    if existing is not None and not args.force:
        raise BoardError(f"board '{args.name}' is registered; --force replaces the fields given")
    probes = attached_probes()
    serial = args.probe
    if not serial and existing:
        serial = existing.get("probe")
    if not serial:
        taken = {b.get("probe") for b in boards.values()}
        free = [s for s in probes if s not in taken]
        if len(free) != 1:
            listed = ", ".join(free) or "none"
            raise BoardError(f"--probe SERIAL is needed: {len(free)} unregistered probes attached ({listed})")
        serial = free[0]
    for other, board in boards.items():
        if other != args.name and board.get("probe") == serial:
            raise BoardError(f"probe {serial} is board '{other}'s")
    board = dict(existing or {})
    board["probe"] = serial
    board["type"] = args.type or board.get("type") or DEFAULT_TYPE
    if args.pool:
        board["pools"] = sorted(set(args.pool), key=args.pool.index)
    board.setdefault("pools", ["dev"])
    if args.power:
        board["power"] = args.power
    elif "power" not in board and serial in probes:
        board["power"] = [probes[serial]["port"]]
    if args.lock is not None:
        if args.lock:
            board["lock"] = args.lock
        else:
            board.pop("lock", None)
    if args.note is not None:
        board["note"] = args.note
    boards[args.name] = board
    save_registry(data)
    where = "attached" if serial in probes else "NOT attached now"
    print(f"board {args.name}: probe {serial} ({where}), pools {','.join(board['pools'])}, "
          f"lock {lock_path(args.name, board)}")
    refresh_installed_fallback(data)
    return 0


def cmd_unregister(args: argparse.Namespace) -> int:
    data = load_registry()
    if data is None or args.name not in data["boards"]:
        raise BoardError(f"no board '{args.name}'")
    del data["boards"][args.name]
    save_registry(data)
    refresh_installed_fallback(data)
    print(f"board {args.name} unregistered")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    data = load_registry()
    boards = boards_of(data)
    probes = attached_probes()
    rows = []
    for name, board in boards.items():
        serial = board.get("probe", "")
        lock = lock_path(name, board)
        rows.append({
            "name": name,
            "type": board.get("type", DEFAULT_TYPE),
            "pools": board.get("pools") or [],
            "probe": serial,
            "attached": serial in probes,
            "tty": (probes.get(serial) or {}).get("tty", ""),
            "power": board.get("power") or [],
            "lock": lock,
            "state": lock_state(lock),
            "reserved": reservation(board),
            "note": board.get("note", ""),
        })
    if args.json:
        print(json.dumps({"registry": str(registry_path()), "exists": data is not None,
                          "boards": rows}, indent=2))
        return 0
    if data is None:
        print(f"no registry ({registry_path()}): single-board mode, lock {LEGACY_LOCK} "
              f"-- {lock_state(LEGACY_LOCK)}")
        return 0
    if not rows:
        print(f"no boards in {registry_path()}")
        return 0
    for row in rows:
        print(f"{row['name']:<8} {','.join(row['pools']):<10} {row['type']:<28} "
              f"probe {row['probe']} {'attached' if row['attached'] else 'NOT ATTACHED'}"
              f"{'  ' + row['note'] if row['note'] else ''}")
        print(f"{'':<8} {row['state']}")
        if row["reserved"]:
            print(f"{'':<8} {describe_reservation(row['reserved'])}")
    return 0


def describe_reservation(held: dict) -> str:
    now = time.time()
    text = f"RESERVED by {held.get('by', '?')} {_age(int(now - float(held.get('since') or now)))} ago"
    until = float(held.get("until") or 0)
    text += f", {_age(int(until - now))} left" if until else ", until released"
    return text + (f": {held['note']}" if held.get("note") else "") + " -- not for CI"


def cmd_reserve(args: argparse.Namespace) -> int:
    data = load_registry()
    if data is None or args.name not in data["boards"]:
        raise BoardError(f"no board '{args.name}'")
    now = time.time()
    held = {"by": f"{getpass.getuser()}@{socket.gethostname()}", "since": int(now),
            "until": int(now + args.hours * 3600) if args.hours > 0 else 0}
    if args.note:
        held["note"] = args.note
    board = data["boards"][args.name]
    board["reserved"] = held
    others = [n for n, b in data["boards"].items()
              if n != args.name and "ci" in (b.get("pools") or []) and reservation(b) is None]
    save_registry(data)
    print(f"board {args.name}: {describe_reservation(held)}")
    state = lock_state(lock_path(args.name, board))
    if not state.startswith("free"):
        print(f"board {args.name} is {state}: that job finishes first")
    if "ci" in (board.get("pools") or []) and not others:
        print("warning: no other board of pool ci is left -- CI waits until a release")
    return 0


def cmd_release(args: argparse.Namespace) -> int:
    data = load_registry()
    if data is None or args.name not in data["boards"]:
        raise BoardError(f"no board '{args.name}'")
    if data["boards"][args.name].pop("reserved", None) is None:
        print(f"board {args.name} was not reserved")
        return 0
    save_registry(data)
    print(f"board {args.name} released")
    return 0


def resolve(args: argparse.Namespace) -> tuple[dict[str, dict], list[str]] | None:
    """The registry's boards and the candidates the arguments name; None = no registry."""
    data = load_registry()
    if data is None:
        if args.board and args.board != "auto":
            raise BoardError(f"--board {args.board}: no board registry ({registry_path()})")
        return None
    board = args.board or os.environ.get("YASOS_BOARD", "").strip() or None
    return data["boards"], candidates(data["boards"], board, args.pool or "dev",
                                      getattr(args, "type", None))


def repicker(args: argparse.Namespace):
    """pick() for acquire: the candidates as the registry says now.  A pool whose
    boards are all reserved has no candidates this round (wait, not fail)."""
    def pick() -> tuple[dict[str, dict], list[str]]:
        try:
            resolved = resolve(args)
        except BoardBusy:
            data = load_registry()
            return boards_of(data), []
        if resolved is None:
            raise BoardError(f"the board registry {registry_path()} went away")
        return resolved
    return pick


def cmd_env(args: argparse.Namespace) -> int:
    resolved = resolve(args)
    if resolved is None:
        env = {"YASOS_BOARD_LOCK": LEGACY_LOCK, "YASOS_RIG_BOARD_COUNT": "0"}
    else:
        boards, names = resolved
        env = board_env(names[0], boards[names[0]], attached_probes(), len(boards))
    if args.json:
        print(json.dumps(env, indent=2))
    else:
        for key, value in env.items():
            print(f"export {key}={shlex.quote(value)}")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise BoardError("run: no command after --")
    what = args.what or os.environ.get("YASOS_BOARD_WHAT") or " ".join(command)[:120]
    resolved = resolve(args)
    env = dict(os.environ)
    if resolved is None:
        # Single-board mode: the lock every tool took before the registry.
        if env.get("YASOS_BOARD_LOCK_HELD") != LEGACY_LOCK:
            fd = try_lock(LEGACY_LOCK)
            if fd is None:
                if not args.quiet:
                    log(f"waiting up to {int(args.wait)} s for {LEGACY_LOCK} -- {lock_state(LEGACY_LOCK)}")
                fd = _open_lock(LEGACY_LOCK)
                if not _flock_wait(fd, args.wait):
                    raise BoardBusy(f"{LEGACY_LOCK} still held after {int(args.wait)} s")
            write_holder(LEGACY_LOCK, "", what)
            os.set_inheritable(fd, True)
        for stale in ("YASOS_BOARD", "YASOS_BOARD_TYPE", "YASOS_BOARD_STATE",
                      "YASOS_PROBE_SERIAL", "YASOS_POWER_PORTS"):
            env.pop(stale, None)  # no boards to speak of
        env["YASOS_BOARD_LOCK"] = LEGACY_LOCK
        env["YASOS_BOARD_LOCK_HELD"] = LEGACY_LOCK
    else:
        boards, name, fd = acquire(repicker(args), args.wait, what, args.quiet)
        if fd is not None:
            os.set_inheritable(fd, True)
        # The caller's UART is not this board's: only board_env may set it.
        env.pop("SERIAL_DEVICE", None)
        env.update(board_env(name, boards[name], attached_probes(), len(boards)))
        env["YASOS_BOARD_LOCK_HELD"] = env["YASOS_BOARD_LOCK"]
        if fd is not None and not args.keeps_state:
            forget_flashed(Path(env["YASOS_BOARD_STATE"]))
        if not args.quiet:
            log(f"board {name} (probe {env['YASOS_PROBE_SERIAL']}, "
                f"uart {env.get('SERIAL_DEVICE') or 'not found'})")
    try:
        os.execvpe(command[0], command, env)
    except OSError as error:
        raise BoardError(f"run: cannot exec {command[0]}: {error}") from error
    return 0  # not reached


def forget_flashed(state: Path) -> None:
    """The board may be flashed by a job that does not record it: forget what it held."""
    for sha in state.glob("*.sha256"):
        try:
            sha.unlink()
        except OSError:
            pass


def _flock_wait(fd: int, wait: float) -> bool:
    deadline = time.monotonic() + max(0.0, wait)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(2.0)


# --- install ----------------------------------------------------------------

def install_root() -> Path:
    return Path.home() / ".local" / "lib" / "yasos-rig"


def fallback_cfg_path() -> Path:
    return Path.home() / ".config" / "openocd" / "interface" / "cmsis-dap.cfg"


FALLBACK_MARK = "# written by yasos scripts/rig/boards.py install"


def fallback_cfg(data: dict | None) -> str:
    """~/.config/openocd's interface/cmsis-dap.cfg: an openocd run that names no probe
    (a tool that does not know the registry) goes to the CI board, never to a board
    someone is working on."""
    boards = boards_of(data)
    ci = [n for n in boards if "ci" in (boards[n].get("pools") or [])]
    default = boards[ci[0]].get("probe", "") if ci else ""
    lines = [
        FALLBACK_MARK,
        "# OpenOCD reads this before its own scripts.  YASOS_PROBE_SERIAL (boards.py run)",
        "# picks the probe; without it, the first board of pool ci"
        + (f" ({ci[0]})." if ci else " (none registered: the first probe)."),
        "adapter driver cmsis-dap",
        "if {[info exists ::env(YASOS_PROBE_SERIAL)] && $::env(YASOS_PROBE_SERIAL) ne \"\"} {",
        "    adapter serial $::env(YASOS_PROBE_SERIAL)",
        "}" + (f" else {{\n    adapter serial {default}\n}}" if default else ""),
        "",
    ]
    return "\n".join(lines)


def refresh_installed_fallback(data: dict | None) -> None:
    path = fallback_cfg_path()
    if path.exists() and FALLBACK_MARK in path.read_text(errors="replace"):
        path.write_text(fallback_cfg(data))


def cmd_install(args: argparse.Namespace) -> int:
    root = install_root()
    (root / "openocd" / "interface").mkdir(parents=True, exist_ok=True)
    (root / "boards.py").write_text(Path(__file__).read_text())
    (root / "boards.py").chmod(0o755)
    (root / "openocd" / "interface" / "cmsis-dap.cfg").write_text(
        (OPENOCD_DIR / "interface" / "cmsis-dap.cfg").read_text())
    bindir = Path.home() / ".local" / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    link = bindir / "yasos-board"
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(root / "boards.py")
    print(f"installed {link} -> {root / 'boards.py'}")
    if not args.no_openocd_fallback:
        cfg = fallback_cfg_path()
        if cfg.exists() and FALLBACK_MARK not in cfg.read_text(errors="replace"):
            print(f"left {cfg} alone: not ours")
        else:
            cfg.parent.mkdir(parents=True, exist_ok=True)
            cfg.write_text(fallback_cfg(load_registry()))
            print(f"wrote {cfg}: openocd runs that name no probe go to the CI board")
    return 0


# --- main -------------------------------------------------------------------

def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Boards on this rig: registry, locks and per-board environment.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("\n\n", 1)[1],
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("scan", help="Debug Probes on the bus")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_scan)

    p = sub.add_parser("register", help="add a board (or change one, --force)")
    p.add_argument("name")
    p.add_argument("--probe", help="probe serial (default: the only unregistered attached probe)")
    p.add_argument("--type", help=f"board profile (default {DEFAULT_TYPE})")
    p.add_argument("--pool", action="append",
                   help="who may use it: ci, dev, ... (repeat; default dev)")
    p.add_argument("--power", action="append", metavar="HUB:PORT",
                   help="uhubctl port that powers it (repeat; default the probe's port)")
    p.add_argument("--lock", help=f"lock file (default {LOCK_DIR}/yasos-board-NAME.lock; '' resets)")
    p.add_argument("--note")
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_register)

    p = sub.add_parser("unregister", help="remove a board")
    p.add_argument("name")
    p.set_defaults(func=cmd_unregister)

    p = sub.add_parser("reserve", help="keep a board for personal work: out of pool ci")
    p.add_argument("name")
    p.add_argument("--hours", type=float, default=24.0,
                   help="how long (default 24; 0 = until `release`)")
    p.add_argument("--note")
    p.set_defaults(func=cmd_reserve)

    p = sub.add_parser("release", help="end a board's reservation")
    p.add_argument("name")
    p.set_defaults(func=cmd_release)

    p = sub.add_parser("list", help="boards and who holds them")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_list)

    for name, func, text in (("env", cmd_env, "a board's environment (no lock)"),
                             ("run", cmd_run, "run a command holding a board")):
        p = sub.add_parser(name, help=text)
        if name == "env":
            p.add_argument("board", nargs="?", help="board name, or auto")
            p.add_argument("--json", action="store_true")
        else:
            p.add_argument("--board", help="board name, or auto (default: $YASOS_BOARD, else auto)")
            p.add_argument("--wait", type=float, default=7200.0,
                           help="seconds to wait for a busy board (default 7200)")
            p.add_argument("--what", help="what the job is, for `list`")
            p.add_argument("--keeps-state", action="store_true",
                           help="CMD records what it flashes in $YASOS_BOARD_STATE "
                                "(without it, the records are deleted)")
            p.add_argument("-q", "--quiet", action="store_true")
            p.add_argument("command", nargs=argparse.REMAINDER)
        p.add_argument("--pool", help="pool to pick from with auto (default dev)")
        p.add_argument("--type", help="only boards of this profile (auto skips others, "
                                      "a named board of another type is an error)")
        p.set_defaults(func=func)

    p = sub.add_parser("install", help="yasos-board in ~/.local/bin for other checkouts")
    p.add_argument("--no-openocd-fallback", action="store_true",
                   help="do not write ~/.config/openocd/interface/cmsis-dap.cfg")
    p.set_defaults(func=cmd_install)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return args.func(args)
    except BoardBusy as error:
        log(str(error))
        return EXIT_BUSY
    except BoardError as error:
        log(str(error))
        return 2


if __name__ == "__main__":
    sys.exit(main())
