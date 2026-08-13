"""Serial-reader behaviour that only shows up against a misbehaving target."""

import io
from pathlib import Path
import subprocess
import sys

import pytest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke.framework import session as session_module
from smoke.framework.session import Session


# What the target prints, over and over, once a user process faults. The first
# line carries one of Session.crash_markers.
FAULT_DUMP = (
    "[ERR][hardfault] HardFault diagnostics:\r\n"
    "[ERR][hardfault]   CFSR=0x00008200 HFSR=0x40000000 BFAR=0x00589004\r\n"
    "[ERR][hardfault]   pid=1 r2=0x00589000 r3=0x00589000\r\n"
)


class EndlessFaultSerial:
    """A target that faulted and now streams diagnostics without pause.

    Never goes quiet, so an idle timeout alone never fires, and never emits the
    prompt or the command echo the reader is waiting for. Gives up after a
    generous number of bytes so a regression fails the test instead of hanging
    it.
    """

    LIMIT = 200_000

    def __init__(self):
        self.timeout = 1.0
        self.served = 0

    def read(self, size=1):
        assert self.served < self.LIMIT, "reader never stopped on the fault dump"
        byte = FAULT_DUMP[self.served % len(FAULT_DUMP)].encode("utf-8")
        self.served += 1
        return byte


@pytest.fixture
def faulting_session(monkeypatch):
    monkeypatch.setattr(Session, "target_crashed", False)
    monkeypatch.setattr(Session, "target_needs_reset", False)
    monkeypatch.setattr(Session, "_collecting", False)
    session = Session.__new__(Session)
    session.serial = EndlessFaultSerial()
    session.file = io.StringIO()
    return session


def test_read_until_stops_once_the_target_starts_dumping_a_fault(faulting_session):
    faulting_session._read_until(Session.prompt, timeout=0.2)

    assert Session.target_crashed
    assert "HardFault diagnostics" in faulting_session.file.getvalue()


def test_wait_for_prompt_reports_the_crash_instead_of_waiting_for_a_prompt(
    faulting_session,
):
    with pytest.raises(RuntimeError, match="crashed"):
        faulting_session.wait_for_prompt_except_logs(timeout=0.2)


def test_wait_for_echo_stops_once_the_target_starts_dumping_a_fault(faulting_session):
    assert faulting_session._wait_for_echo("tcc /root/ci/sources/tests2/x.c") is False

    assert Session.target_crashed


def test_write_command_raises_on_a_crashed_target(faulting_session):
    def _write(_data):
        return None

    faulting_session.serial.write = _write

    with pytest.raises(RuntimeError, match="crashed"):
        faulting_session.write_command("tcc /root/ci/sources/tests2/x.c")


def test_reader_still_logs_everything_it_consumed(faulting_session):
    text = faulting_session._read_until(Session.prompt, timeout=0.2)

    # Incremental logging must not drop or duplicate the tail: what the caller
    # is handed and what the log holds have to agree.
    assert faulting_session.file.getvalue() == text


# A real boot banner: well past RECORD_CHUNK, so the reader flushes (and scans)
# mid-read at least once before the prompt arrives, and carrying none of the
# crash markers -- the PSRAM lines are ERR-level but perfectly healthy.
BOOT_BANNER = (
    "[ERR][hal_external_memory] PSRAM rxdelay 0: fail\r\n"
    "[ERR][hal_external_memory] PSRAM rxdelay 1: fail\r\n"
    "[ERR][hal_external_memory] PSRAM rxdelay 2: fail\r\n"
    "[ERR][hal_external_memory] PSRAM rxdelay 3: pass\r\n"
    "[ERR][hal_external_memory] PSRAM rxdelay 4: pass\r\n"
    "[ERR][hal_external_memory] PSRAM rxdelay 5: pass\r\n"
    "[ERR][hal_external_memory] PSRAM rxdelay calibrated: window [3..7], chosen 5\r\n"
    "[ERR][default] Initializing ARM Cortex-M context switching...\r\n"
    "$ "
)


class RebootingSerial:
    """A board that just came back up and is printing its banner."""

    def __init__(self, text=BOOT_BANNER):
        self.timeout = 1.0
        self.text = text.encode("utf-8")
        self.pos = 0

    def read(self, size=1):
        chunk = self.text[self.pos:self.pos + size]
        self.pos += len(chunk)
        return chunk

    def reset_input_buffer(self):
        pass

    @property
    def in_waiting(self):
        return len(self.text) - self.pos


@pytest.fixture
def rebooted_session(monkeypatch):
    """A session whose board crashed and has since been reset."""
    monkeypatch.setattr(Session, "target_crashed", True)
    monkeypatch.setattr(Session, "target_needs_reset", True)
    monkeypatch.setattr(Session, "_collecting", False)
    monkeypatch.setattr(Session, "backend", None)
    session = Session.__new__(Session)
    session.serial = RebootingSerial()
    session.file = io.StringIO()
    return session


def test_boot_after_a_crash_is_read_to_the_prompt(rebooted_session):
    # The crash flag is still set from the boot the reset just ended. It
    # describes bytes that are already gone, so it must not abort this read:
    # doing so stopped the banner after one RECORD_CHUNK flush, and the prompt
    # that arrives right after it was never seen.
    text = rebooted_session._read_until(Session.prompt, timeout=0.5)

    assert text.endswith(Session.prompt)


def test_reset_recovers_a_crashed_board_without_escalating(rebooted_session, monkeypatch):
    escalations = []

    # Let the real reset_target() run -- clearing the crash flag is the part
    # under test -- and only stub out the shell script it shells out to.
    def _run(*_args, **_kwargs):
        rebooted_session.serial = RebootingSerial()
        return subprocess.CompletedProcess(args="./reset_target.sh", returncode=0, stdout=b"")

    monkeypatch.setattr(session_module.subprocess, "run", _run)
    monkeypatch.setattr(
        Session, "power_reset_target",
        lambda self: escalations.append("power") or False)
    monkeypatch.setattr(
        Session, "reflash_target",
        lambda self: escalations.append("reflash") or False)

    rebooted_session._reset_and_wait_for_prompt()

    # One crash used to cost a USB power cycle and a full reflash per remaining
    # test, none of which could help: the board was booting fine all along.
    assert escalations == []
    assert not Session.target_crashed
    assert not Session.target_needs_reset


def test_session_logs_land_in_the_runs_own_directory(tmp_path, monkeypatch):
    """The remote runner gives each run its own numbered directory (logs/1,
    logs/2, ...) so two runs can be compared; every artifact of a run has to
    follow it there, transcripts included."""
    from smoke.framework.paths import smoke_log_dir

    monkeypatch.delenv("YASOS_SMOKE_LOG_DIR", raising=False)
    monkeypatch.chdir(tmp_path)
    assert smoke_log_dir() == Path("logs")

    run_dir = tmp_path / "logs" / "7"
    monkeypatch.setenv("YASOS_SMOKE_LOG_DIR", str(run_dir))
    assert smoke_log_dir() == run_dir
