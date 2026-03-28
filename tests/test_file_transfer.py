from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parent / "smoke"))

from framework import file_transfer as ft


class FakeSerial:
    def __init__(self, incoming: bytes):
        if isinstance(incoming, (bytes, bytearray)):
            self._reads = [bytes(incoming)]
        else:
            self._reads = [item for item in incoming]
        self.written = bytearray()
        self.timeout = 1.0

    def read(self, size: int = 1) -> bytes:
        if size <= 0:
            return b""
        while self._reads:
            current = self._reads[0]
            if current is None:
                self._reads.pop(0)
                return b""
            if not current:
                self._reads.pop(0)
                continue
            chunk = current[:size]
            remainder = current[size:]
            if remainder:
                self._reads[0] = remainder
            else:
                self._reads.pop(0)
            return bytes(chunk)
        return b""

    def write(self, data: bytes) -> int:
        self.written.extend(data)
        return len(data)

    def flush(self):
        pass

    def reset_input_buffer(self):
        pass


class FakeSession:
    def __init__(self, serial):
        self.serial = serial
        self.commands = []

    def write_command(self, command: str) -> None:
        self.commands.append(command)

    def wait_for_prompt_except_logs(self):
        return ["OK 4"]


def test_recv_header_skips_stray_zdle_sequence():
    valid_header = ft._build_header(ft.ZACK, 0, 0, 0, 4)
    serial = FakeSerial(b"noise" + bytes([ft.ZPAD, ft.ZDLE, ft.ZCRCW]) + valid_header)

    header = ft._recv_header(serial)

    assert header == (ft.ZACK, [0, 0, 0, 4])


def test_recv_header_skips_bad_crc_candidate_before_valid_header():
    bad_header = bytearray(ft._build_header(ft.ZACK, 0, 0, 0, 1))
    bad_header[-1] ^= 0x01
    valid_header = ft._build_header(ft.ZACK, 0, 0, 0, 4)
    serial = FakeSerial(bytes(bad_header) + valid_header)

    header = ft._recv_header(serial)

    assert header == (ft.ZACK, [0, 0, 0, 4])


def test_send_file_tolerates_echoed_zdle_sequence_before_zack(tmp_path):
    local_path = tmp_path / "sample.c"
    local_path.write_bytes(b"test")

    zack = ft._build_header(ft.ZACK, 0, 0, 0, 4)
    incoming = b"".join([
        ft._build_header(ft.ZRINIT, 0, ft.CANFDX | ft.ESCCTL, 0, 0),
        ft._build_header(ft.ZRPOS, 0, 0, 0, 0),
        bytes([ft.ZPAD, ft.ZDLE, ft.ZCRCW]),
        zack,
        ft._build_header(ft.ZFIN, 0, 0, 0, 0),
    ])
    session = FakeSession(FakeSerial(incoming))

    ft.send_file(session, str(local_path), "/tmp/sample.c")

    assert session.commands == ["rz --zmodem /tmp/sample.c"]
    assert session.serial.written.endswith(ft._build_header(ft.ZFIN, 0, 0, 0, 0))


def test_send_file_tolerates_bad_crc_candidate_before_zack(tmp_path):
    local_path = tmp_path / "sample.c"
    local_path.write_bytes(b"test")

    bad_header = bytearray(ft._build_header(ft.ZACK, 0, 0, 0, 1))
    bad_header[-1] ^= 0x01
    incoming = b"".join([
        ft._build_header(ft.ZRINIT, 0, ft.CANFDX | ft.ESCCTL, 0, 0),
        ft._build_header(ft.ZRPOS, 0, 0, 0, 0),
        bytes(bad_header),
        ft._build_header(ft.ZACK, 0, 0, 0, 4),
        ft._build_header(ft.ZFIN, 0, 0, 0, 0),
    ])
    session = FakeSession(FakeSerial(incoming))

    ft.send_file(session, str(local_path), "/tmp/sample.c")

    assert session.commands == ["rz --zmodem /tmp/sample.c"]


def test_send_file_requests_ack_for_each_nonfinal_chunk(tmp_path):
    local_path = tmp_path / "sample.c"
    payload = b"a" * (ft.DATA_SUBPACKET_SIZE + 10)
    local_path.write_bytes(payload)

    incoming = b"".join([
        ft._build_header(ft.ZRINIT, 0, ft.CANFDX | ft.ESCCTL, 0, 0),
        ft._build_header(ft.ZRPOS, 0, 0, 0, 0),
        ft._build_header(ft.ZACK, 0, 0, 4, 0),
        ft._build_header(ft.ZACK, 0, 0, 4, 10),
        ft._build_header(ft.ZFIN, 0, 0, 0, 0),
    ])
    session = FakeSession(FakeSerial(incoming))

    ft.send_file(session, str(local_path), "/tmp/sample.c")

    expected_nonfinal_packet = ft._build_data_subpacket(payload[:ft.DATA_SUBPACKET_SIZE], ft.ZCRCQ)
    expected_final_packet = ft._build_data_subpacket(payload[ft.DATA_SUBPACKET_SIZE:], ft.ZCRCW)
    assert expected_nonfinal_packet in session.serial.written
    assert expected_final_packet in session.serial.written


def test_send_file_retries_chunk_after_timeout(tmp_path):
    local_path = tmp_path / "sample.c"
    payload = b"a" * (ft.DATA_SUBPACKET_SIZE + 10)
    local_path.write_bytes(payload)

    incoming = [
        ft._build_header(ft.ZRINIT, 0, ft.CANFDX | ft.ESCCTL, 0, 0),
        ft._build_header(ft.ZRPOS, 0, 0, 0, 0),
        None,
        None,
        ft._build_header(ft.ZACK, 0, 0, 4, 0),
        ft._build_header(ft.ZACK, 0, 0, 4, 10),
        ft._build_header(ft.ZFIN, 0, 0, 0, 0),
    ]
    session = FakeSession(FakeSerial(incoming))

    ft.send_file(session, str(local_path), "/tmp/sample.c")

    first_chunk_packet = ft._build_data_subpacket(payload[:ft.DATA_SUBPACKET_SIZE], ft.ZCRCQ)
    assert session.serial.written.count(first_chunk_packet) == 2
    assert session.serial.written.count(ft._build_header(ft.ZDATA, 0, 0, 0, 0)) == 2


def test_send_file_rewinds_to_requested_offset(tmp_path):
    local_path = tmp_path / "sample.c"
    payload = b"a" * (ft.DATA_SUBPACKET_SIZE + 10)
    local_path.write_bytes(payload)

    second_chunk_start = ft.DATA_SUBPACKET_SIZE
    incoming = [
        ft._build_header(ft.ZRINIT, 0, ft.CANFDX | ft.ESCCTL, 0, 0),
        ft._build_header(ft.ZRPOS, 0, 0, 0, 0),
        ft._build_header(ft.ZACK, 0, 0, 4, 0),
        # ZRPOS with no following ZACK — genuine rewind request
        ft._build_header(ft.ZRPOS, 0, 0, 4, 0),
        None,
        ft._build_header(ft.ZACK, 0, 0, 4, 10),
        ft._build_header(ft.ZFIN, 0, 0, 0, 0),
    ]
    session = FakeSession(FakeSerial(incoming))

    ft.send_file(session, str(local_path), "/tmp/sample.c")

    resumed_header = ft._build_header(ft.ZDATA, 0, 0, 4, 0)
    final_packet = ft._build_data_subpacket(payload[second_chunk_start:], ft.ZCRCW)
    assert session.serial.written.count(resumed_header) == 1
    assert session.serial.written.count(final_packet) == 2


def test_send_file_ignores_stale_zrpos_before_zack(tmp_path):
    """A stale ZRPOS followed immediately by a valid ZACK should not cause a restart."""
    local_path = tmp_path / "sample.c"
    payload = b"a" * (ft.DATA_SUBPACKET_SIZE + 10)
    local_path.write_bytes(payload)

    second_chunk_start = ft.DATA_SUBPACKET_SIZE
    incoming = [
        ft._build_header(ft.ZRINIT, 0, ft.CANFDX | ft.ESCCTL, 0, 0),
        ft._build_header(ft.ZRPOS, 0, 0, 0, 0),
        ft._build_header(ft.ZACK, 0, 0, 4, 0),
        # Stale ZRPOS followed immediately by the real ZACK
        ft._build_header(ft.ZRPOS, 0, 0, 4, 0),
        ft._build_header(ft.ZACK, 0, 0, 4, 10),
        ft._build_header(ft.ZFIN, 0, 0, 0, 0),
    ]
    session = FakeSession(FakeSerial(incoming))

    ft.send_file(session, str(local_path), "/tmp/sample.c")

    # The stale ZRPOS should be ignored, so the final packet is sent only once
    final_packet = ft._build_data_subpacket(payload[second_chunk_start:], ft.ZCRCW)
    assert session.serial.written.count(final_packet) == 1