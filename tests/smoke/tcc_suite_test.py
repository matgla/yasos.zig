"""
 Copyright (c) 2025 Mateusz Stadnik

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
 """

from .conftest import session_key
import random
from dataclasses import dataclass

import logging
import hashlib
import re
import shlex
import posixpath

from typing import Optional, Union, Any

from ymodem.Socket import ModemSocket
from ymodem.Protocol import ProtocolType

import os

import pytest

current_session = None
logger = logging.getLogger(__name__)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class ProgressLine:
    def __init__(self, testcase):
        _ = testcase

    def update(self, state):
        _ = state

    def finish(self, state="done"):
        _ = state

def read(size: int, timeout: Optional[float] = 3) -> any:
        return current_session.read_raw(size, timeout)

def write(data: Union[bytes, bytearray], timeout: Optional[float] = 3) -> any:
        current_session.write_raw(data, timeout)

@dataclass(frozen=True)
class TccTestCase:
    test_id: str
    name: str
    sources: tuple[str, ...]
    support_files: tuple[tuple[str, str], ...] = ()
    cflags: tuple[str, ...] = ()
    args: tuple[str, ...] = ()
    expected_lines: Optional[tuple[str, ...]] = None
    expected_exit_code: int = 0


REGISTERED_SINGLE_FILE_TESTS = [
    "00_assignment.c",
    "01_comment.c",
    "02_printf.c",
    "03_struct.c",
    "04_for.c",
    "05_array.c",
    "06_case.c",
    "07_function.c",
    "08_while.c",
    "09_do_while.c",
    "10_pointer.c",
    "11_precedence.c",
    "12_hashdefine.c",
    "13_integer_literals.c",
    "14_if.c",
    "15_recursion.c",
    "16_nesting.c",
    "17_enum.c",
    "19_pointer_arithmetic.c",
    "20_pointer_comparison.c",
    "21_char_array.c",
    "22_floating_point.c",
    "23_type_coercion.c",
    "24_math_library.c",
    "25_quicksort.c",
    "26_character_constants.c",
    "27_sizeof.c",
    "28_strings.c",
    "29_array_address.c",
    "30_hanoi.c",
    "32_led.c",
    "33_ternary_op.c",
    "34_array_assignment.c",
    "35_sizeof.c",
    "36_array_initialisers.c",
    "37_sprintf.c",
    "38_multiple_array_index.c",
    "39_typedef.c",
    "41_hashif.c",
    "42_function_pointer.c",
    "43_void_param.c",
    "44_scoped_declarations.c",
    "45_empty_for.c",
    "47_switch_return.c",
    "48_nested_break.c",
    "49_bracket_evaluation.c",
    "50_logical_second_arg.c",
    "51_static.c",
    "52_unnamed_enum.c",
    "54_goto.c",
    "55_lshift_type.c",
    "61_integers.c",
    "64_macro_nesting.c",
    "67_macro_concat.c",
    "70_floating_point_literals.c",
    "71_macro_empty_arg.c",
    "72_long_long_constant.c",
    "73_arm64.c",
    "75_array_in_struct_init.c",
    "76_dollars_in_identifiers.c",
    "77_push_pop_macro.c",
    "78_vla_label.c",
    "79_vla_continue.c",
    "80_flexarray.c",
    "81_types.c",
    "82_attribs_position.c",
    "83_utf8_in_identifiers.c",
    "84_hex-float.c",
    "85_asm-outside-function.c",
    "86_memory-model.c",
    "87_dead_code.c",
    "88_codeopt.c",
    "89_nocode_wanted.c",
    "90_struct-init.c",
    "91_ptr_longlong_arith32.c",
    "92_enum_bitfield.c",
    "93_integer_promotion.c",
    "94_generic.c",
    "97_utf8_string_literal.c",
    "100_c99array-decls.c",
    "102_alignas.c",
    "103_implicit_memmove.c",
    "105_local_extern.c",
    "107_stack_safe.c",
    "108_constructor.c",
    "109_float_struct_calling.c",
    "110_average.c",
    "111_conversion.c",
    "118_switch.c",
    "119_random_stuff.c",
    "121_struct_return.c",
    "122_vla_reuse.c",
    "123_vla_bug.c",
    "129_scopes.c",
    "130_large_argument.c",
    "131_return_struct_in_reg.c",
    "132_bound_test.c",
    "133_string_concat.c",
    "134_double_to_signed.c",
    "135_func_arg_struct_compare.c",
    "138_jmp_branch.c",
]

REGISTERED_TESTS_WITH_ARGS = [
    ("31_args.c", ("arg1", "arg2", "arg3", "arg4", "arg5")),
]

REGISTERED_MULTI_FILE_TESTS = [
    TccTestCase(
        test_id="18_include.c",
        name="18_include.c",
        sources=("18_include.c",),
        support_files=(
            ("18_include.h", "18_include.h"),
            ("18_include2.h", "18_include2.h"),
            ("18_include2.h", "../tests2/18_include2.h"),
        ),
    ),
    TccTestCase(
        test_id="104_inline.c",
        name="104_inline.c",
        sources=("104_inline.c", "104+_inline.c"),
    ),
    TccTestCase(
        test_id="120_alias.c",
        name="120_alias.c",
        sources=("120_alias.c", "120+_alias.c"),
    ),
]

REGISTERED_TAGGED_TEST_FILES = [
    "60_errors_and_warnings.c",
    "95_bitfields.c",
    "96_nodata_wanted.c",
    "128_run_atexit.c",
]

SMOKE_DISABLED_TESTS = {
    "101_cleanup.c",
    "106_versym.c",
    "112_backtrace.c",
    "113_btdll.c",
    "114_bound_signal.c",
    "124_atomic_counter.c",
    "125_atomic_misc.c",
    "126_bound_globals.c",
    "127_asm_goto.c",
    "73_arm64.c",
    "95_bitfields_ms.c",
    "98_al_ax_extend.c",
    "99_fastcall.c",
    "90_al_ax_extend.c",
}

FLOAT_TOLERANCE_TESTS = {
    "22_floating_point.c",
    "24_math_library.c",
}

FLOAT_RELATIVE_TOLERANCE = 1e-4


def lines_match_with_float_tolerance(expected, actual, rel_tol):
    """Compare two lines, allowing floating-point values to differ within rel_tol."""
    expected_tokens = expected.split()
    actual_tokens = actual.split()
    if len(expected_tokens) != len(actual_tokens):
        return False
    for exp_tok, act_tok in zip(expected_tokens, actual_tokens):
        if exp_tok == act_tok:
            continue
        try:
            exp_val = float(exp_tok)
            act_val = float(act_tok)
        except ValueError:
            return False
        if exp_val == 0.0 and act_val == 0.0:
            continue
        denom = max(abs(exp_val), abs(act_val))
        if denom == 0.0 or abs(exp_val - act_val) / denom > rel_tol:
            return False
    return True

RETURNS_PATTERN = re.compile(r"^\[returns (\d+)\]$")
TAG_PATTERN = re.compile(r"^\[([a-zA-Z_][a-zA-Z0-9_]*(?:=[^\]]+)?)\]$")
SHA256_LINE_PATTERN = re.compile(r"^(?P<digest>[0-9a-f]{64})(?:\s+.+)?$", re.IGNORECASE)
EXIT_MARKER_PREFIX = "__EXIT_STATUS__:"
COMPILE_MARKER_PREFIX = "__COMPILE_STATUS__:"


def build_tcc_test_cases():
    test_cases = []

    for source_name in REGISTERED_SINGLE_FILE_TESTS:
        if source_name in SMOKE_DISABLED_TESTS:
            continue
        test_cases.append(TccTestCase(test_id=source_name, name=source_name, sources=(source_name,)))

    for source_name, args in REGISTERED_TESTS_WITH_ARGS:
        if source_name in SMOKE_DISABLED_TESTS:
            continue
        test_cases.append(TccTestCase(test_id=source_name, name=source_name, sources=(source_name,), args=args))

    for test_case in REGISTERED_MULTI_FILE_TESTS:
        if any(source_name in SMOKE_DISABLED_TESTS for source_name in test_case.sources):
            continue
        test_cases.append(test_case)

    for source_name in REGISTERED_TAGGED_TEST_FILES:
        if source_name in SMOKE_DISABLED_TESTS:
            continue
        tagged_expectations = parse_tagged_expect_file(source_name)
        for tag, expectation in tagged_expectations.items():
            test_cases.append(
                TccTestCase(
                    test_id=f"{source_name}[{tag}]",
                    name=source_name,
                    sources=(source_name,),
                    cflags=(f"-D{tag}",),
                    expected_lines=tuple(expectation["lines"]),
                    expected_exit_code=expectation["exit_code"],
                )
            )

    return test_cases


def load_expect_file(source_name):
    expect = os.path.join(path, source_name.replace(".c", ".expect"))
    assert os.path.exists(expect), f"expect file not found: {expect}"

    expected_lines = []
    expected_exit_code = 0
    with open(expect, "r") as handle:
        for raw_line in handle:
            stripped_line = raw_line.strip()
            if not stripped_line:
                continue

            returns_match = RETURNS_PATTERN.match(stripped_line)
            if returns_match:
                expected_exit_code = int(returns_match.group(1))
                continue

            expected_lines.append(stripped_line)

    return tuple(expected_lines), expected_exit_code


def parse_tagged_expect_file(source_name):
    expect = os.path.join(path, source_name.replace(".c", ".expect"))
    assert os.path.exists(expect), f"expect file not found: {expect}"

    tags = {}
    current_tag = None
    with open(expect, "r") as handle:
        for raw_line in handle:
            stripped_line = raw_line.strip()
            if not stripped_line:
                continue

            tag_match = TAG_PATTERN.match(stripped_line)
            if tag_match:
                current_tag = tag_match.group(1)
                tags[current_tag] = {"lines": [], "exit_code": 0}
                continue

            returns_match = RETURNS_PATTERN.match(stripped_line)
            if returns_match and current_tag is not None:
                tags[current_tag]["exit_code"] = int(returns_match.group(1))
                continue

            if current_tag is not None:
                tags[current_tag]["lines"].append(stripped_line)

    return tags

def send_file(filename, socket, session):
    session.write_command("rz")
    data = session.read_until("Starting YMODEM receiver...")
    socket.send([filename])
    session.wait_for_prompt_except_logs()


def remote_test_path(relative_path):
    return posixpath.normpath(posixpath.join("/root/tcc_test", relative_path))

def get_remote_hash(relative_path, session):
    session.write_command("sha256sum " + shlex.quote(remote_test_path(relative_path)))
    data = session.wait_for_prompt_except_logs()
    if not data:
        return None

    first_line = data[0].strip()
    if "No such file or directory" in first_line:
        return None

    hash_match = SHA256_LINE_PATTERN.match(first_line)
    if hash_match is None:
        return None

    return hash_match.group("digest").lower()

def upload_testcase(local_path, remote_relative_path, socket, session):
    filename = os.path.basename(remote_relative_path)
    remote_path = remote_test_path(remote_relative_path)
    remote_dir = posixpath.dirname(remote_path)
    remote_hash = get_remote_hash(remote_relative_path, session)
    upload_state = "checking hash"

    if remote_hash is None:
        upload_state = "uploading"
        session.write_command("mkdir -p " + shlex.quote(remote_dir))
        session.wait_for_prompt_except_logs()
        session.write_command("cd " + shlex.quote(remote_dir))
        session.wait_for_prompt_except_logs()
        session.write_command("rz")
        data = session.read_until("Starting YMODEM receiver...")
        socket.send([local_path])
        session.wait_for_prompt_except_logs()
        session.write_command("cd /root/tcc_test")
        session.wait_for_prompt_except_logs()

    local_hash = sha256_file(local_path)
    if remote_hash is None:
        remote_hash = get_remote_hash(remote_relative_path, session)
        assert remote_hash is not None, "file upload failed, missing remote hash"

    if local_hash != remote_hash:
        upload_state = "re-uploading"
        session.write_command("rm " + shlex.quote(remote_path))
        session.wait_for_prompt_except_logs()
        session.write_command("cd " + shlex.quote(remote_dir))
        session.wait_for_prompt_except_logs()
        session.write_command("rz")
        data = session.read_until("Starting YMODEM receiver...")
        socket.send([local_path])
        session.wait_for_prompt_except_logs()
        session.write_command("cd /root/tcc_test")
        session.wait_for_prompt_except_logs()

        remote_hash = get_remote_hash(remote_relative_path, session)
        assert remote_hash is not None, "file upload failed, missing remote hash"
        assert local_hash == remote_hash, "file upload failed, hash mismatch"

    if upload_state == "checking hash":
        return "cached"
    return upload_state

def upload_test_sources(testcase, socket, session):
    upload_states = []
    for source_name in testcase.sources:
        upload_states.append(upload_testcase(os.path.join(path, source_name), source_name, socket, session))
    for local_name, remote_name in testcase.support_files:
        upload_states.append(upload_testcase(os.path.join(path, local_name), remote_name, socket, session))

    if not upload_states:
        return "cached"
    if any(state == "re-uploading" for state in upload_states):
        return "re-uploading"
    if any(state == "uploading" for state in upload_states):
        return "uploading"
    return "cached"


def testcase_binary_name(testcase):
    return testcase.name.replace(".c", "")


def compile_testcase(testcase, socket, session):
    filename_without_extension = testcase_binary_name(testcase)
    source_args = " ".join(shlex.quote(remote_test_path(source_name)) for source_name in testcase.sources)
    flag_args = " ".join(testcase.cflags)
    compile_args = " ".join(arg for arg in (source_args, flag_args) if arg)
    session.write_command(f"rm -f {filename_without_extension}")
    session.wait_for_prompt_except_logs()
    session.write_command(f"tcc {compile_args} -o {filename_without_extension}")
    compile_lines = session.wait_for_prompt_except_logs()

    expected_lines = testcase.expected_lines
    expected_exit_code = testcase.expected_exit_code
    if expected_lines is None:
        expected_lines, expected_exit_code = load_expect_file(testcase.name)

    source_basename = os.path.basename(testcase.name)
    compile_expected_lines = []
    runtime_expected_lines = []
    for expected_line in expected_lines:
        if source_basename in expected_line:
            compile_expected_lines.append(expected_line)
        else:
            runtime_expected_lines.append(expected_line)

    compile_output = "\n".join(compile_lines)
    for expected_line in compile_expected_lines:
        assert expected_line in compile_output, f"expected compile-time line '{expected_line}' in '{compile_lines}'"

    if not runtime_expected_lines and expected_exit_code == 0:
        return

    quoted_args = " ".join(shlex.quote(argument) for argument in testcase.args)
    run_command = f"/root/tcc_test/{filename_without_extension}"
    if quoted_args:
        run_command = f"{run_command} {quoted_args}"
    session.write_command(f"{run_command}; echo {EXIT_MARKER_PREFIX}$?")
    data_lines = session.wait_for_prompt_except_logs()

    actual_exit_code = None
    filtered_lines = []
    for line in data_lines:
        if line.startswith(EXIT_MARKER_PREFIX):
            actual_exit_code = int(line[len(EXIT_MARKER_PREFIX):])
            continue
        filtered_lines.append(line)

    assert actual_exit_code is not None, f"missing exit status in output: {data_lines}"
    use_float_tolerance = testcase.name in FLOAT_TOLERANCE_TESTS
    for index, expected_line in enumerate(runtime_expected_lines):
        actual_line = filtered_lines[index].strip()
        if use_float_tolerance:
            assert lines_match_with_float_tolerance(expected_line, actual_line, FLOAT_RELATIVE_TOLERANCE), \
                f"expected '{expected_line}' to match '{actual_line}' within tolerance {FLOAT_RELATIVE_TOLERANCE}"
        else:
            assert expected_line in actual_line, f"expected '{expected_line}' in '{filtered_lines}'"
    assert actual_exit_code == expected_exit_code, f"expected exit code {expected_exit_code}, got {actual_exit_code}"

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../libs/tinycc/tests/tests2")

test_cases = build_tcc_test_cases()
test_cases = sorted(test_cases, key=lambda testcase: testcase.test_id)



@pytest.mark.flaky(reruns=0)
@pytest.mark.parametrize('testcase', test_cases, ids=[testcase.test_id for testcase in test_cases])
def test_run_tcc_test_suite(request, testcase):
    session = request.node.stash[session_key]
    global current_session
    current_session = session
    session.write_command("mkdir -p /root/tcc_test")
    data = session.wait_for_prompt_except_logs()
    session.write_command("cd /root/tcc_test")

    socket_args = {
        "packet_size": 1024,
        "protocol_type": ProtocolType.YMODEM,
    }

    logging.getLogger("YMODEM").setLevel(logging.WARNING)

    socket = ModemSocket(read, write, **socket_args)
    progress = ProgressLine(testcase.test_id)
    try:
        upload_state = upload_test_sources(testcase, socket, session)
        progress.update(upload_state)
        progress.update("compiling")
        compile_testcase(testcase, socket, session)
    except Exception:
        progress.finish("failed")
        raise
    progress.finish("ok")





