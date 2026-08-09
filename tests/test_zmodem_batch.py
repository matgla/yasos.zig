"""End-to-end test of the batch zmodem transfer, host sender against target receiver.

The receiver is the actual ``apps/rzsz`` C code, compiled for the host and
driven over a pair of pipes: the protocol is the part that cannot be reasoned
about from either side alone, and getting it wrong on hardware costs a rootfs
rebuild, a reflash and a serial session per attempt.

Skipped when there is no C compiler on the machine running the tests.
"""

import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tests"))

from smoke.framework import file_transfer  # noqa: E402

RZSZ_DIR = REPO_ROOT / "apps" / "rzsz"

# The receiver calls klog_ctl() to silence kernel logging on the shared UART,
# which only exists on the target.
KLOG_STUB = """#pragma once
static inline int klog_ctl(int enable) { (void)enable; return 0; }
"""

# A main() that skips prepare_terminal() -- the pipes this test uses are not
# terminals, and the tty setup is not what is under test.
TEST_MAIN = """#include "zmodem/zmodem.h"

/* terminal.c is target-only (tty ioctls on the serial console); a pipe has no
   driver-side buffer to drop. */
void flush_stdin(void) {}

/* With a path: the single-file mode the suite has always used. Without: batch. */
int main(int argc, char *argv[]) {
  int rc = argc > 1 ? zmodem_receive(argv[1]) : zmodem_receive_batch();
  return rc < 0 ? 1 : 0;
}
"""


@pytest.fixture(scope="module")
def receiver_binary(tmp_path_factory):
    compiler = shutil.which("cc") or shutil.which("gcc")
    if compiler is None:
        pytest.skip("no host C compiler available")

    build_dir = tmp_path_factory.mktemp("rzsz_host")
    (build_dir / "sys").mkdir()
    (build_dir / "sys" / "klog.h").write_text(KLOG_STUB)
    (build_dir / "batch_main.c").write_text(TEST_MAIN)

    binary = build_dir / "rz_batch"
    result = subprocess.run(
        [
            compiler, "-O0", "-g",
            f"-I{build_dir}", f"-I{RZSZ_DIR}",
            str(build_dir / "batch_main.c"),
            str(RZSZ_DIR / "zmodem" / "zmodem.c"),
            str(RZSZ_DIR / "crc16.c"),
            "-o", str(binary),
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        pytest.skip(f"host build of the zmodem receiver failed: {result.stderr}")
    return binary


class _PipeSerial:
    """The slice of pyserial's API that file_transfer uses, over two pipes."""

    def __init__(self, read_fd, write_fd):
        self._read_fd = read_fd
        self._write_fd = write_fd
        self.timeout = 5.0

    def read(self, count):
        try:
            return os.read(self._read_fd, count)
        except OSError:
            return b""

    def write(self, data):
        return os.write(self._write_fd, data)

    def flush(self):
        pass

    def reset_input_buffer(self):
        pass


class _FakeSession:
    """Stands in for framework.session.Session around a live receiver process."""

    def __init__(self, serial):
        self.serial = serial
        self.commands = []
        self.recorded = []

    def write_command(self, command):
        # The receiver is already running; the command that would have started
        # it is only recorded so the test can assert on it.
        self.commands.append(command)

    def wait_for_prompt_except_logs(self, timeout=None):
        return []

    def _record_serial_output(self, text):
        self.recorded.append(text)


def _run_batch(receiver_binary, transfers, workdir):
    """Send *transfers* to a freshly spawned receiver, return the fake session."""
    host_to_target_r, host_to_target_w = os.pipe()
    target_to_host_r, target_to_host_w = os.pipe()

    process = subprocess.Popen(
        [str(receiver_binary)],
        stdin=host_to_target_r,
        stdout=target_to_host_w,
        stderr=subprocess.PIPE,
        cwd=str(workdir),
    )
    os.close(host_to_target_r)
    os.close(target_to_host_w)

    serial = _PipeSerial(target_to_host_r, host_to_target_w)
    session = _FakeSession(serial)

    # A protocol bug shows up as both sides waiting forever; fail the test
    # instead of hanging the suite.
    failure = []

    def _drive():
        try:
            session.sent_bytes = file_transfer.send_files(session, transfers)
        except BaseException as error:  # noqa: BLE001 - reported below
            failure.append(error)

    driver = threading.Thread(target=_drive, daemon=True)
    driver.start()
    driver.join(timeout=60)
    assert not driver.is_alive(), "the sender hung"

    process.wait(timeout=30)
    os.close(target_to_host_r)
    os.close(host_to_target_w)

    if failure:
        raise failure[0]
    assert process.returncode == 0, "the receiver exited non-zero"
    return session


def test_batch_writes_every_file_with_its_own_path(receiver_binary, tmp_path):
    root = tmp_path / "target"
    sources = tmp_path / "host"
    sources.mkdir()

    # Nested directories the receiver has to create, plus content that exercises
    # ZDLE escaping (0x18) and the control bytes ESCCTL covers.
    payloads = {
        "sources/tests2/00_assignment.c": b"int main(void) { return 0; }\n",
        "sources/tests2/01_comment.c": b"/* comment */\n",
        "sources/gcc_torture/execute/920501.c": bytes(range(256)) * 3,
        "sources/deep/nested/dir/tree/file.h": b"#pragma once\n",
        "sources/empty.c": b"",
    }
    transfers = []
    for index, (relative, content) in enumerate(payloads.items()):
        local = sources / f"file{index}.bin"
        local.write_bytes(content)
        transfers.append((str(local), f"{root}/{relative}"))

    session = _run_batch(receiver_binary, transfers, tmp_path)

    # One spawn for the whole batch, then a single round trip for the target's
    # receive-loss counters -- the batch is the one place the link is driven
    # flat out, so it is where those numbers are worth reading.
    assert session.commands == ["rz --zmodem --batch", "cat /proc/uart"]
    for relative, content in payloads.items():
        assert (root / relative).read_bytes() == content
    assert session.sent_bytes == sum(len(c) for c in payloads.values())


def test_batch_of_one_file_still_completes(receiver_binary, tmp_path):
    root = tmp_path / "target"
    local = tmp_path / "only.c"
    local.write_bytes(b"int x;\n")

    _run_batch(receiver_binary, [(str(local), f"{root}/ci/only.c")], tmp_path)

    assert (root / "ci" / "only.c").read_bytes() == b"int x;\n"


def test_batch_overwrites_a_stale_target_copy(receiver_binary, tmp_path):
    root = tmp_path / "target" / "ci"
    root.mkdir(parents=True)
    # Longer than the new content: a receiver that opened without O_TRUNC would
    # leave the tail of this behind.
    (root / "stale.c").write_bytes(b"old content that is longer\n")

    local = tmp_path / "fresh.c"
    local.write_bytes(b"new\n")
    _run_batch(receiver_binary, [(str(local), f"{root}/stale.c")], tmp_path)

    assert (root / "stale.c").read_bytes() == b"new\n"


def test_send_files_reports_progress_per_file(receiver_binary, tmp_path):
    root = tmp_path / "target"
    transfers = []
    for index in range(4):
        local = tmp_path / f"src{index}.c"
        local.write_bytes(b"x" * (index + 1))
        transfers.append((str(local), f"{root}/ci/src{index}.c"))

    progress = []
    host_to_target_r, host_to_target_w = os.pipe()
    target_to_host_r, target_to_host_w = os.pipe()
    process = subprocess.Popen(
        [str(receiver_binary)],
        stdin=host_to_target_r, stdout=target_to_host_w,
        stderr=subprocess.PIPE, cwd=str(tmp_path),
    )
    os.close(host_to_target_r)
    os.close(target_to_host_w)
    session = _FakeSession(_PipeSerial(target_to_host_r, host_to_target_w))

    file_transfer.send_files(
        session, transfers,
        on_progress=lambda done, total, sent: progress.append((done, total, sent)),
    )
    process.wait(timeout=30)
    os.close(target_to_host_r)
    os.close(host_to_target_w)

    assert [entry[0] for entry in progress] == [1, 2, 3, 4]
    assert {entry[1] for entry in progress} == {4}
    assert [entry[2] for entry in progress] == [1, 3, 6, 10]


def test_single_file_transfer_still_works(receiver_binary, tmp_path):
    """The one-file path shares the body helper with the batch; both must hold.

    Its handshake differs in exactly one place: the receiver answers ZEOF with
    ZFIN rather than another ZRINIT.
    """
    local = tmp_path / "source.c"
    local.write_bytes(bytes(range(256)) + b"int main(void){return 0;}\n")
    destination = tmp_path / "target" / "one.c"
    destination.parent.mkdir(parents=True)

    host_to_target_r, host_to_target_w = os.pipe()
    target_to_host_r, target_to_host_w = os.pipe()
    process = subprocess.Popen(
        [str(receiver_binary), str(destination)],
        stdin=host_to_target_r, stdout=target_to_host_w,
        stderr=subprocess.PIPE, cwd=str(tmp_path),
    )
    os.close(host_to_target_r)
    os.close(target_to_host_w)
    session = _FakeSession(_PipeSerial(target_to_host_r, host_to_target_w))

    file_transfer.send_file(session, str(local), str(destination))
    process.wait(timeout=30)
    os.close(target_to_host_r)
    os.close(host_to_target_w)

    assert process.returncode == 0
    assert destination.read_bytes() == local.read_bytes()
    assert session.commands == [f"rz --zmodem {destination}"]


def test_send_files_with_nothing_to_send_never_starts_the_receiver(tmp_path):
    session = _FakeSession(_PipeSerial(-1, -1))
    assert file_transfer.send_files(session, []) == 0
    assert session.commands == []


# ---- wire burst budget ----
#
# The link between the host and the target's UART pin drops whatever a single
# uninterrupted write pushes past its buffer, so the sender has to size bursts
# by their *encoded* length. These do not need the receiver, only the encoder.

def _encoded_burst_length(chunk: bytes) -> int:
    """What one sub-packet actually costs on the wire, header included."""
    return len(file_transfer._build_header(file_transfer.ZDATA, 0, 0, 0, 0)) + len(
        file_transfer._build_data_subpacket(chunk, file_transfer.ZCRCQ)
    )


@pytest.mark.parametrize("payload", [
    b"int main(void) { return 0; }\n" * 400,          # ordinary C source
    bytes(range(256)) * 40,                            # every byte value
    bytes([file_transfer.ZDLE]) * 4096,                # every byte needs escaping
    bytes([0x11, 0x13, 0x18, 0x0d]) * 1024,            # the control bytes ESCCTL covers
])
def test_no_chunk_exceeds_the_wire_burst_budget(payload):
    offset = 0
    while offset < len(payload):
        end = file_transfer._chunk_end_within_wire_budget(payload, offset)
        assert end > offset, "chunker must always make progress"
        assert _encoded_burst_length(payload[offset:end]) <= file_transfer.WIRE_BURST_BUDGET
        offset = end


def test_chunker_uses_the_budget_it_has():
    """Escape-free payloads should not be split more than the budget requires."""
    payload = b"a" * 4096
    end = file_transfer._chunk_end_within_wire_budget(payload, 0)
    assert end == file_transfer.WIRE_BURST_BUDGET - file_transfer.WIRE_BURST_OVERHEAD


def test_chunker_halves_the_payload_when_every_byte_is_escaped():
    payload = bytes([file_transfer.ZDLE]) * 4096
    end = file_transfer._chunk_end_within_wire_budget(payload, 0)
    assert end == (file_transfer.WIRE_BURST_BUDGET - file_transfer.WIRE_BURST_OVERHEAD) // 2


# ---- link accounting ----
#
# The target prints its cumulative received-byte count on every sub-packet
# failure. Comparing it against what the host has written is what separates a
# wire that eats bytes from a target that loses them after receiving them.

def test_link_accounting_reports_no_drift_when_every_byte_arrives(capsys):
    link = file_transfer._LinkAccounting()
    # The target has been counting since boot, so it starts 1000 ahead; that
    # constant offset is exactly what the baseline absorbs.
    link.observe(b"RZDBG subpacket fail: len=704 rx=4000 ovr=0\n", 5000)
    link.observe(b"RZDBG subpacket fail: len=688 rx=9000 ovr=0\n", 10000)

    out = capsys.readouterr().out
    assert "baseline set" in out
    assert "drift +0 bytes" in out


def test_link_accounting_reports_bytes_the_wire_ate(capsys):
    link = file_transfer._LinkAccounting()
    link.observe(b"RZDBG fail rx=4000\n", 5000)
    # Target received 48 fewer than the host sent since the baseline.
    link.observe(b"RZDBG fail rx=8952\n", 10000)

    assert "drift +48 bytes" in capsys.readouterr().out


def test_link_accounting_survives_a_line_split_across_reads(capsys):
    link = file_transfer._LinkAccounting()
    link.observe(b"RZDBG subpacket fail: len=704 r", 5000)
    link.observe(b"x=4000 ovr=0 drop=0\n", 5000)

    assert "baseline set (target rx=4000" in capsys.readouterr().out
