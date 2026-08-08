"""
 Copyright (c) 2026 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.


 The loader refuses a YAFF image this machine cannot execute, instead of
 running code compiled for hardware that is not here (which fails as a fault,
 or -- for a mismatched float ABI -- as silently wrong results).

 Each case takes a known-good executable, corrupts exactly one field of its
 architecture description on the host, uploads it, and checks the loader says
 no. The unpatched control proves the upload path itself is sound, so a
 rejection can only come from the patch.
"""

import os
import struct
import tempfile

import pytest

from .conftest import session_key
from .framework.file_transfer import send_file

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# 1.3 KiB, prints one unmistakable line: cheap to upload once per case.
DONOR = os.path.join(REPO_ROOT, "rootfs", "usr", "bin", "hello")
DONOR_OUTPUT = "Hello, World!"

# Field offsets in the packed 92-byte YaffHeader (libs/tinycc/source/obj/tccyaff.h).
HDR_ARCH = 5  # uint16
HDR_YAFF_VERSION = 7  # uint8
HDR_ARCH_SECTION_OFFSET = 60  # uint16

# Field offsets inside YaffArchSection.
SEC_FPU = 3  # uint8
SEC_FLOAT_ABI = 4  # uint8
SEC_REQUIRED_FEATURES = 8  # uint32

YAFF_ARCH_ARMV6_M = 1
YAFF_FLOAT_ABI_HARD = 2
YAFF_ARCH_FEATURE_FPU_DP = 1 << 1


def _read_donor():
    with open(DONOR, "rb") as f:
        image = bytearray(f.read())
    assert image[0:4] == b"YAFF", f"{DONOR} is not a YAFF image"
    return image


def _arch_section_offset(image):
    (offset,) = struct.unpack_from("<H", image, HDR_ARCH_SECTION_OFFSET)
    assert offset != 0, "donor image carries no architecture section"
    return offset


def _run_image(session, image, remote_name):
    """Upload `image` as /tmp/<remote_name>, run it, return the serial output."""
    with tempfile.TemporaryDirectory() as tmp:
        local_path = os.path.join(tmp, remote_name)
        with open(local_path, "wb") as f:
            f.write(image)
        remote_path = "/tmp/" + remote_name
        session.write_command("rm -f " + remote_path)
        session.wait_for_prompt_except_logs()
        send_file(session, local_path, remote_path)

    session.write_command(remote_path)
    return session.wait_for_prompt(timeout=10)


def _assert_refused(output, reason):
    assert reason in output, (
        f"expected the loader to refuse the image with {reason}, got:\n{output}"
    )
    assert DONOR_OUTPUT not in output, (
        f"image ran despite {reason}:\n{output}"
    )


def test_accepts_unmodified_image(request):
    """Control: the donor uploaded byte-for-byte still runs."""
    session = request.node.stash[session_key]
    output = _run_image(session, _read_donor(), "yaff_ok")
    assert DONOR_OUTPUT in output, output
    assert "[ERR][yasld]" not in output, output


def test_rejects_other_architecture(request):
    session = request.node.stash[session_key]
    image = _read_donor()
    struct.pack_into("<H", image, HDR_ARCH, YAFF_ARCH_ARMV6_M)
    output = _run_image(session, image, "yaff_arch")
    _assert_refused(output, "UnsupportedArchitecture")


def test_rejects_unknown_format_version(request):
    session = request.node.stash[session_key]
    image = _read_donor()
    struct.pack_into("<B", image, HDR_YAFF_VERSION, 1)
    output = _run_image(session, image, "yaff_ver")
    _assert_refused(output, "UnsupportedYaffVersion")


def test_rejects_missing_arch_section(request):
    session = request.node.stash[session_key]
    image = _read_donor()
    struct.pack_into("<H", image, HDR_ARCH_SECTION_OFFSET, 0)
    output = _run_image(session, image, "yaff_nosec")
    _assert_refused(output, "MissingArchSection")


def test_rejects_absent_fpu_feature(request):
    """No yasos target has a double-precision FPU, so this can never be met."""
    session = request.node.stash[session_key]
    image = _read_donor()
    section = _arch_section_offset(image)
    (features,) = struct.unpack_from("<I", image, section + SEC_REQUIRED_FEATURES)
    struct.pack_into(
        "<I", image, section + SEC_REQUIRED_FEATURES, features | YAFF_ARCH_FEATURE_FPU_DP
    )
    output = _run_image(session, image, "yaff_fpu")
    _assert_refused(output, "UnsupportedCpuFeatures")


def test_rejects_hard_float_abi(request):
    session = request.node.stash[session_key]
    image = _read_donor()
    section = _arch_section_offset(image)
    struct.pack_into("<B", image, section + SEC_FLOAT_ABI, YAFF_FLOAT_ABI_HARD)
    output = _run_image(session, image, "yaff_abi")
    _assert_refused(output, "UnsupportedFloatAbi")
