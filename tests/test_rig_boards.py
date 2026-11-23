"""scripts/rig/boards.py: the rig's board registry, pools, locks and environment."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

TOOL = Path(__file__).resolve().parent.parent / "scripts" / "rig" / "boards.py"


@pytest.fixture
def rig(tmp_path):
    """A fake rig: two Debug Probes in sysfs (AAAA with a by-id UART), locks and state in tmp."""
    devices = tmp_path / "sys" / "bus" / "usb" / "devices"
    for name, serial in (("1-1", "AAAA"), ("3-1", "BBBB")):
        dev = devices / name
        dev.mkdir(parents=True)
        (dev / "idVendor").write_text("2e8a\n")
        (dev / "idProduct").write_text("000c\n")
        (dev / "serial").write_text(serial + "\n")
    (devices / "3-1" / "3-1:1.1" / "tty" / "ttyACM1").mkdir(parents=True)
    by_id = tmp_path / "by-id"
    by_id.mkdir()
    (by_id / "usb-Raspberry_Pi_Debugprobe_on_Pico__CMSIS-DAP__AAAA-if01").touch()
    env = dict(os.environ)
    env.update({
        "YASOS_RIG_SYSFS": str(tmp_path / "sys"),
        "YASOS_RIG_SERIAL_BY_ID": str(by_id),
        "YASOS_RIG_BOARDS": str(tmp_path / "boards.json"),
        "YASOS_RIG_STATE": str(tmp_path / "state"),
        "YASOS_RIG_LOCK_DIR": str(tmp_path),
        "YASOS_RIG_LEGACY_LOCK": str(tmp_path / "legacy.lock"),
    })
    for key in ("YASOS_BOARD", "YASOS_BOARD_LOCK_HELD", "YASOS_PROBE_SERIAL"):
        env.pop(key, None)

    def boards(*args, check=True, extra_env=None):
        run_env = dict(env, **(extra_env or {}))
        result = subprocess.run([sys.executable, str(TOOL), *args], env=run_env,
                                capture_output=True, text=True, timeout=60)
        if check and result.returncode != 0:
            raise AssertionError(f"boards.py {' '.join(args)}: rc {result.returncode}\n{result.stderr}")
        return result

    boards.tmp = tmp_path
    boards.env = env
    return boards


def _registered(rig):
    rig("register", "a", "--probe", "AAAA", "--pool", "ci", "--pool", "dev",
        "--lock", str(rig.tmp / "legacy.lock"))
    rig("register", "b", "--pool", "dev")  # the only unregistered probe left: BBBB


def test_register_takes_the_only_unregistered_probe(rig):
    first = rig("register", "a", check=False)
    assert first.returncode == 2 and "2 unregistered probes" in first.stderr
    _registered(rig)
    data = json.loads((rig.tmp / "boards.json").read_text())
    assert data["boards"]["b"]["probe"] == "BBBB"
    assert data["boards"]["b"]["power"] == ["3:1"]
    taken = rig("register", "c", "--probe", "AAAA", check=False)
    assert taken.returncode == 2 and "board 'a'" in taken.stderr


def test_env_of_a_board(rig):
    _registered(rig)
    env = json.loads(rig("env", "a", "--json").stdout)
    assert env["YASOS_PROBE_SERIAL"] == "AAAA"
    assert env["SERIAL_DEVICE"].endswith("CMSIS-DAP__AAAA-if01")
    assert env["YASOS_POWER_PORTS"] == "1:1"
    assert env["OPENOCD_SCRIPTS"].endswith("scripts/rig/openocd")
    assert env["YASOS_BOARD_LOCK"] == str(rig.tmp / "legacy.lock")
    # No by-id link: the tty under the probe's interface.
    assert json.loads(rig("env", "b", "--json").stdout)["SERIAL_DEVICE"] == "/dev/ttyACM1"


def test_pool_prefers_the_dedicated_board_and_falls_back_to_the_shared_one(rig):
    _registered(rig)
    assert "YASOS_BOARD=b" in rig("env", "--pool", "dev").stdout
    assert "YASOS_BOARD=a" in rig("env", "--pool", "ci").stdout
    holder = subprocess.Popen([sys.executable, str(TOOL), "run", "--board", "b", "--", "sleep", "5"],
                              env=rig.env, stderr=subprocess.PIPE, text=True)
    try:
        _wait_for_holder(rig.tmp / "yasos-board-b.lock.holder")
        got = rig("run", "--pool", "dev", "--wait", "0", "--", "sh", "-c", "echo $YASOS_BOARD")
        assert got.stdout.strip() == "a"
        busy = rig("run", "--board", "b", "--wait", "0", "--", "true", check=False)
        assert busy.returncode == 99 and "busy" in busy.stderr
        assert "busy: sleep 5" in rig("list").stdout
    finally:
        holder.kill()
        holder.wait()


def test_nested_run_for_the_held_board_does_not_wait_on_itself(rig):
    _registered(rig)
    inner = f"{sys.executable} {TOOL} run --wait 0 -- sh -c 'echo inner $YASOS_BOARD'"
    out = rig("run", "--board", "b", "--wait", "0", "--", "sh", "-c", inner).stdout
    assert out.strip() == "inner b"


def test_a_job_that_does_not_keep_the_records_drops_them(rig):
    _registered(rig)
    state = rig.tmp / "state" / "boards" / "a"
    state.mkdir(parents=True)
    (state / "kernel.sha256").write_text("x\n")
    rig("run", "--board", "a", "--keeps-state", "--", "true")
    assert (state / "kernel.sha256").exists()
    rig("run", "--board", "a", "--", "true")  # e.g. a CI job, which flashes unrecorded
    assert not (state / "kernel.sha256").exists()


def test_type_filter(rig):
    _registered(rig)
    rig("register", "b", "--force", "--type", "mspc_v2")
    assert "YASOS_BOARD=a" in rig("env", "--pool", "dev", "--type", "pimoroni_pico_plus2_and_vga").stdout
    wrong = rig("run", "--board", "b", "--type", "pimoroni_pico_plus2_and_vga", "--", "true", check=False)
    assert wrong.returncode == 2 and "mspc_v2" in wrong.stderr


def test_without_a_registry_the_legacy_lock_is_taken(rig):
    out = rig("run", "--", "sh", "-c", "echo $YASOS_BOARD_LOCK_HELD ${YASOS_PROBE_SERIAL:-none}").stdout
    assert out.split() == [str(rig.tmp / "legacy.lock"), "none"]
    named = rig("run", "--board", "a", "--", "true", check=False)
    assert named.returncode == 2 and "no board registry" in named.stderr


def _wait_for_holder(path, timeout=10.0):
    deadline = time.monotonic() + timeout
    while not path.exists():
        assert time.monotonic() < deadline, f"{path} never appeared"
        time.sleep(0.05)


def _both_shared(rig):
    rig("register", "a", "--probe", "AAAA", "--pool", "ci", "--pool", "dev",
        "--lock", str(rig.tmp / "legacy.lock"))
    rig("register", "b", "--pool", "ci", "--pool", "dev")


def test_two_shared_boards_ci_and_dev_start_on_different_ones(rig):
    _both_shared(rig)
    assert "YASOS_BOARD=a" in rig("env", "--pool", "ci").stdout
    assert "YASOS_BOARD=b" in rig("env", "--pool", "dev").stdout


def test_a_reserved_board_leaves_pool_ci_and_comes_first_for_dev(rig):
    _both_shared(rig)
    out = rig("reserve", "a", "--hours", "0", "--note", "long debug").stdout
    assert "until released" in out and "long debug" in out
    assert "YASOS_BOARD=b" in rig("env", "--pool", "ci").stdout
    assert "YASOS_BOARD=a" in rig("env", "--pool", "dev").stdout
    assert "RESERVED by" in rig("list").stdout
    # Explicitly named, it is taken anyway.
    assert rig("run", "--board", "a", "--", "sh", "-c", "echo $YASOS_BOARD").stdout.strip() == "a"
    # Both reserved: CI waits (here 0 s) and says why.
    assert "no other board of pool ci" in rig("reserve", "b").stdout
    busy = rig("run", "--pool", "ci", "--wait", "0", "--", "true", check=False)
    assert busy.returncode == 99 and "reserved" in busy.stderr
    rig("release", "b")
    assert rig("run", "--pool", "ci", "--wait", "0", "--", "sh", "-c",
               "echo $YASOS_BOARD").stdout.strip() == "b"


def test_a_reservation_expires(rig):
    _both_shared(rig)
    rig("reserve", "a", "--hours", "0.0001")
    time.sleep(0.5)
    assert "YASOS_BOARD=a" in rig("env", "--pool", "ci").stdout
    assert "RESERVED" not in rig("list").stdout


def test_ci_waiting_for_a_board_picks_up_a_release(rig):
    _both_shared(rig)
    rig("reserve", "a")
    holder = subprocess.Popen([sys.executable, str(TOOL), "run", "--board", "b", "--", "sleep", "30"],
                              env=rig.env, stderr=subprocess.PIPE, text=True)
    try:
        _wait_for_holder(rig.tmp / "yasos-board-b.lock.holder")
        waiter = subprocess.Popen([sys.executable, str(TOOL), "run", "--pool", "ci", "--wait", "20",
                                   "--", "sh", "-c", "echo $YASOS_BOARD"],
                                  env=rig.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(1)
        rig("release", "a")
        out, err = waiter.communicate(timeout=20)
        assert out.strip() == "a", err
    finally:
        holder.kill()
        holder.wait()
