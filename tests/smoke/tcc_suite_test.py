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

import logging
import subprocess

from typing import Optional, Union, Any

from ymodem.Socket import ModemSocket
from ymodem.Protocol import ProtocolType

import os

import pytest

current_session = None

def read(size: int, timeout: Optional[float] = 3) -> any:
        return current_session.read_raw(size, timeout)

def write(data: Union[bytes, bytearray], timeout: Optional[float] = 3) -> any:
        current_session.write_raw(data, timeout)

def find_tcc_test_cases(path):
    test_cases = []
    for root, dirs, files in os.walk(path):
        for file in files:
            if file.endswith(".c"):
                test_cases.append(os.path.join(root, file))
    return test_cases

def send_file(filename, socket, session):
    session.write_command("rz")
    data = session.read_until("Starting YMODEM receiver...")
    socket.send([filename])
    session.wait_for_prompt_except_logs()

def upload_testcase(path, socket, session):
    filename = os.path.basename(path)
    session.write_command("ls /root/tcc_test")
    data = session.wait_for_prompt_except_logs()
    has_file = False
    for line in data:
        if filename in line:
            has_file = True
            break
    if not has_file:
        session.write_command("rz")
        data = session.read_until("Starting YMODEM receiver...")
        socket.send([path])
        session.wait_for_prompt_except_logs()

    session.write_command("sha256sum /root/tcc_test/" + filename)
    data = session.read_line_except_logs()
    subprocess.run(["sha256sum", path], check=True)
    local_hash = subprocess.check_output(["sha256sum", path]).decode().split()[0]
    remote_hash = data.split()[0]
    if local_hash != remote_hash:
        session.write_command("rm /root/tcc_test/" + filename)
        session.write_command("rz")
        data = session.read_until("Starting YMODEM receiver...")
        socket.send([path])
        session.wait_for_prompt_except_logs()

        session.write_command("sha256sum /root/tcc_test/" + filename)
        data = session.read_line_except_logs()
        subprocess.run(["sha256sum", path], check=True)
        local_hash = subprocess.check_output(["sha256sum", path]).decode().split()[0]
        assert local_hash == data.split()[0], "file upload failed, hash mismatch"

def compile_testcase(filename, socket, session):
    filename_without_extension = filename.replace(".c", "")
    session.write_command(f"tcc /root/tcc_test/{filename} -o {filename_without_extension}")
    data_lines = session.wait_for_prompt_except_logs()
    session.write_command("/root/tcc_test/" + filename_without_extension)
    data_lines = data_lines[:-1]
    run_lines = session.wait_for_prompt_except_logs()[:-1]
    data_lines += run_lines
    expect_path = path + "/" + filename
    expect = expect_path.replace(".c", ".expect")
    assert os.path.exists(expect), f"expect file not found: {expect}"
    with open(expect, "r") as f:
        i = 0
        for expected_line in f:
            expected_line = expected_line.strip()
            assert expected_line in data_lines[i].strip(), f"expected '{expected_line}' in '{data_lines}'"
            i += 1

removed_test_cases = [
    "101_cleanup.c",  # preprocessed file > 4MB is size is to large for MCU
    "102_alignas.c",   # fixme
    "104+_inline.c",  #xcheckme
    "104_inline.c",
    "106_versym.c",
    "107_stack_safe.c",
    "109_float_struct_calling.c",
    "110_average.c",
    "111_conversion.c",
    "112_backtrace.c",
    "113_btdll.c",
    "114_bound_signal.c",
    "119_random_stuff.c",
    "117_builtins.c",
    "120_alias.c",
    "120+_alias.c",
    "121_struct_return.c",
    "124_atomic_counter.c",
    "125_atomic_misc.c",
    "126_bound_globals.c",
    "127_asm_goto.c",
    "131_return_struct_in_reg.c",
    "132_bound_test.c",
    "115_bound_setjmp.c",
    "116_bound_setjmp2.c",
    "108_constructor.c",
    "18_include.c",
    "22_floating_point.c",
    "23_type_coercion.c",
    "24_math_library.c",
    "33_ternary_op.c",
    "49_bracket_evaluation.c",
    "70_floating_point_literals.c",
    "73_arm64.c",
    "84_hex-float.c",
    "109_float_struct_calling.c",
    "134_double_to_signed.c",
    "126_bound_global.c",
    "78_vla_label.c",
    "118_switch.c",
    "11_precedence.c",
    "122_vla_reuse.c",
    "128_run_atexit.c",
    "130_large_argument.c",
    "31_args.c",
    "34_array_assignment.c",
    "39_typedef.c",
    "42_function_pointer.c",
    "46_grep.c",
    "50_logical_second_arg.c",
    "60_errors_and_warnings.c",
    "61_integers.c",
    "71_macro_empty_arg.c",
    "78_vla_label.c",
    "79_vla_continue.c",
    "83_utf8_in_identifiers.c",
    "85_asm-outside-function.c",
    "90_struct-init.c",
    "91_ptr_longlong_arith32.c",
    "94_generic.c",
    "95_bitfields.c",
    "95_bitfields_ms.c",
    "96_nodata_wanted.c",
    "90_al_ax_extend.c",
    "99_fastcall.c",
    "76_dollars_in_identifiers.c",
    "77_push_pop_macro.c",
    "90_struct-init.c",
    "98_al_ax_extend.c"
]

path = "../../libs/tinycc/tests/tests2"

test_cases = [os.path.basename(tc) for tc in find_tcc_test_cases(path)]
test_cases = [tc for tc in test_cases if not any(os.path.basename(tc) == os.path.basename(removed) for removed in removed_test_cases)]
test_cases = sorted(test_cases)



@pytest.mark.parametrize('testcase', test_cases)
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

    logging.basicConfig(level=logging.DEBUG, format='%(message)s')
    logger = logging.getLogger('YMODEM')
    logger.setLevel(logging.DEBUG)

    socket = ModemSocket(read, write, **socket_args)
    print("Uploading testcase:", testcase)
    upload_testcase(path + "/" + testcase, socket, session)
    compile_testcase(testcase, socket, session)





