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
from .timing import (
    timing_results,
    start_timer,
    elapsed_ms,
    attach_loader_timing,
    attach_compile_profile,
    attach_kernel_profile,
    begin_case,
    end_case,
    record,
    add as add_timing,
)
from .profiling import profiling_enabled, extract_profile_lines, record_profile
import random
import time
from dataclasses import dataclass, replace
import importlib.util

import json
import pathlib
import logging
import hashlib
import re
import shlex
import posixpath
import sys
from pathlib import Path, PurePosixPath

from typing import Optional, Any

import os
import zlib

import pytest

from .framework.file_transfer import send_file as serial_send_file
from .framework.file_transfer import send_files as serial_send_files

logger = logging.getLogger(__name__)

REMOTE_CI_ROOT = "/root/ci"
# Versioned, because the layout below it changed (see "Source sharding"), and a
# FAT directory that still holds the previous layout's ~1700 flat files would
# have to be walked to reach the new bucket directories -- which is the cost
# sharding exists to remove. A new root sidesteps that without a device-side
# `rm -rf` of 4500 files, each of which pays the very walk we are avoiding.
# The previous tree is left behind (~4 MiB); delete /root/ci/sources/tests2,
# /ir_tests and /gcc_torture by hand to reclaim it.
# Where the sources live on the device. Normally under the CI root on writable
# storage, filled by the ZMODEM push below.
#
# YASOS_SMOKE_SOURCES_ROOT overrides it so a run can point at a filesystem the
# host prepared instead: under QEMU the fatdisk window is a slice of the file
# backing guest RAM, so scripts/build_smoke_fatdisk.py can write the whole corpus
# straight into it and the guest mounts it at /mnt with nothing transferred at
# all. That matters because the RAM-backed disk is reformatted on every boot and
# the harness relaunches qemu between tests -- re-pushing 4.13 MiB each time is
# the single largest cost in a run.
REMOTE_SOURCES_ROOT = os.environ.get("YASOS_SMOKE_SOURCES_ROOT", "").strip() or \
    posixpath.join(REMOTE_CI_ROOT, "sources", "v2")
REMOTE_TESTS2_DIR = posixpath.join(REMOTE_SOURCES_ROOT, "tests2")
REMOTE_IR_TESTS_DIR = posixpath.join(REMOTE_SOURCES_ROOT, "ir_tests")
REMOTE_GCC_COMPILE_DIR = posixpath.join(REMOTE_SOURCES_ROOT, "gcc_torture", "compile")
REMOTE_GCC_EXECUTE_DIR = posixpath.join(REMOTE_SOURCES_ROOT, "gcc_torture", "execute")
REMOTE_OUTPUT_DIR = "/tmp"
REMOTE_PERSISTENT_OUTPUT_DIR = posixpath.join(REMOTE_CI_ROOT, "output")

EXTRA_TCC_CFLAGS = tuple(os.environ.get("YASOS_EXTRA_TCC_CFLAGS", "").split()) if os.environ.get("YASOS_EXTRA_TCC_CFLAGS", "").strip() else ()

# On-target compiles take longer than ordinary shell commands, so the compile
# phase always waits at least this long; a per-testcase ``timeout`` overrides
# it for known-slow cases (it also raises the run-phase silence limit).
def _compile_timeout_default():
    """5 s at the reference clock, scaled for whatever the firmware was built for.

    A fixed 5 s is a statement about the *board*, not about the test: at 618 MHz
    it comfortably covers every compile except the handful listed in
    COMPILE_TIMEOUT_TESTS, but a run at a lower clock is proportionally slower
    everywhere and the limit starts tripping on ordinary tests. The symptom is
    misleading -- the compile succeeds, the harness just stops listening first,
    so it surfaces as "Prompt not found" and looks like a miscompile.

    Read from config/target/config.json (rsynced to the rig, so it is the same
    file the kernel was built from) rather than from an env var, because the
    runner forwards no environment to the remote pytest.
    """
    override = os.environ.get("YASOS_SMOKE_COMPILE_TIMEOUT")
    if override:
        return float(override)
    reference_mhz = 618.0
    base = 5.0
    try:
        config_path = pathlib.Path(__file__).resolve().parents[2] / "config" / "target" / "config.json"
        with config_path.open() as handle:
            mhz = float(json.load(handle)["cpu_clock_frequency_mhz"])
        if mhz > 0:
            # Never shorten below the reference: a faster clock does not make a
            # too-tight deadline safe, and the slow cases are already listed.
            return max(base, base * reference_mhz / mhz)
    except (OSError, KeyError, ValueError, TypeError):
        pass
    return base


COMPILE_TIMEOUT = _compile_timeout_default()

# When a compile overruns its serial-read deadline the device is usually STILL
# compiling (tcc is silent while it works, so the idle-timeout tripped before
# it finished). Before a rerun we passively wait up to this long for that
# in-flight job to finish and land on a prompt, so its late output doesn't
# corrupt the rerun's commands. Idle seconds: a live-but-slow target keeps
# resetting the window, only a genuinely dead line waits the whole budget.
RERUN_SETTLE_TIMEOUT = float(os.environ.get("YASOS_SMOKE_RERUN_SETTLE_TIMEOUT", "60"))

REPO_ROOT = Path(__file__).resolve().parents[2]
TINYCC_TESTS_ROOT = REPO_ROOT / "libs" / "tinycc" / "tests"
GCC_TESTS_DIR = TINYCC_TESTS_ROOT / "gcctestsuite"

ENABLE_GCC_TORTURE_SMOKE = os.environ.get("YASOS_SMOKE_ENABLE_GCC_TORTURE", "").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}

_gcc_spec = importlib.util.spec_from_file_location("tinycc_gcc_conftest", GCC_TESTS_DIR / "conftest.py")
_gcc_conftest = importlib.util.module_from_spec(_gcc_spec)
assert _gcc_spec is not None and _gcc_spec.loader is not None
_gcc_spec.loader.exec_module(_gcc_conftest)

GCC_TORTURE_PATH = _gcc_conftest.GCC_TORTURE_PATH
GCC_OPT_LEVELS = _gcc_conftest.get_opt_levels(
    env_var="YASOS_SMOKE_TCC_OPT_LEVELS",
    default=("-O0",),
)
# All suites (gcc-torture, tests2, ir_tests) iterate GCC_OPT_LEVELS so the
# selected -O flags are actually passed to tcc. Every runner -- the QEMU gate,
# the packaged hardware run and the remote TUI -- selects all three by default;
# a single level is the focused case, picked with --opt-levels /
# --smoke-tcc-opt-levels. With one level configured the tests2/ir_tests ids are
# left untagged for backward compatibility; with several, each variant is
# tagged [-ON] like the gcc-torture suites. The default here stays -O0 (tcc's
# own default) so a bare pytest run with no env var set is unchanged.
SMOKE_OPT_CFLAGS = tuple(GCC_OPT_LEVELS[:1])


def _with_smoke_opt(cflags):
    """Prepend the first selected smoke optimization level to a test's cflags."""
    return SMOKE_OPT_CFLAGS + tuple(cflags)


def _opt_level_variants(base_test_id, base_cflags=()):
    """Yield (test_id, cflags) for each configured smoke optimization level.

    With a single configured level the test_id is returned untagged (preserving
    the remote-TUI/default ids); with multiple levels each variant is tagged
    [-ON] and prepends that level to the test's cflags.
    """
    base_cflags = tuple(base_cflags)
    multi = len(GCC_OPT_LEVELS) > 1
    for opt_level in GCC_OPT_LEVELS:
        test_id = f"{base_test_id}[{opt_level}]" if multi else base_test_id
        yield test_id, (opt_level,) + base_cflags
discover_gcc_execute_tests = _gcc_conftest.discover_gcc_execute_tests
discover_gcc_compile_tests = _gcc_conftest.discover_gcc_compile_tests
should_skip_gcc_test = _gcc_conftest.should_skip_gcc_test
is_xfail_test = _gcc_conftest.is_xfail_test
is_xfail_o1_test = _gcc_conftest.is_xfail_o1_test

# Tests skipped only on the native embedded target: they run fine on a PC but
# hit a property of this hardware -- mostly resource exhaustion, plus the DCP's
# lack of subnormal support at the bottom of the table.
NATIVE_TARGET_SKIP_TESTS = {
    # compile/ tests — resource exhaustion on the embedded target
    "compile/20001226-1": "compile-time OOM: emits 'memory full'",
    "compile/pr46534": "compile-time OOM: emits 'memory full'",
    "compile/limits-blockid": "pathological limits test: compile-time OOM",
    "compile/limits-enumconst": "pathological limits test: compile-time OOM",
    "compile/limits-externalid": "pathological limits test: compile-time OOM",
    "compile/limits-externdecl": "pathological limits test: compile-time OOM",
    "compile/limits-exprparen": "compile-time process stack overflow on target",
    "compile/limits-structnest": "compile-time process stack overflow on target",
    "compile/limits-caselabels": "memory and performance optimization needed",
    "compile/limits-declparen": "compile-time process stack overflow on target",
    # 1 MB string-literal array (STR6 ~10^6 bytes): exhausts target memory and
    # crashes QEMU. gcc's own testsuite dg-skip-if's this as "Array too big" on
    # small-memory targets (avr/m32c/pdp11/msp430); same rationale here.
    "compile/limits-stringlit": "1 MB string-literal array: target OOM (gcc dg-skip-if 'Array too big')",
    # execute/ tests — compile phase exhausts process stack before link/run
    "memcpy-a1": "test is to huge to run on the embedded target",
    "memclr": "test is to huge to run on the embedded target",
    "memcpy-a2": "test is to huge to run on the embedded target",
    "memcpy-a4": "test is to huge to run on the embedded target",
    "memcpy-a8": "test is to huge to run on the embedded target",
    "107_mibench_remaining": "test is too large to run on the embedded target",
    # 16384 macro-expanded cleanup blocks need ~60MB of compiler heap (host
    # measurement); the whole on-target process pool is ~7MB → genuine OOM.
    "115_cleanup_macro_unroll": "compile-time OOM: needs ~60MB heap, target pool is 7MB",
    # ---- RP2350 DCP: no subnormal support in the compare ----
    # Doubles are compared with the DCP's WXUP/WYUP/ADD0/RCMP sequence (exactly
    # what pico-sdk's dcp_dcmp_m emits), and WXUP flushes a subnormal to zero.
    # Measured on the device: a double with bits 0x0000000000000FFE compares
    # EQUAL to 0.0.  Every resulting error is a spurious "equal", since ordering
    # against a normal value still comes out right.
    #
    # This is a property of the silicon, not of tcc -- gcc built against
    # pico-sdk's double_aeabi_dcp.S behaves the same way, and the datasheet
    # documents no subnormal handling.  Correcting it means either ~10 extra
    # instructions on every inline double compare or turning all of them into
    # calls, which is a real cost to pay for two conformance vectors.  The
    # sibling defect that WAS worth fixing -- the DCP flushing subnormal results
    # in double->float -- is handled in software; see
    # libs/tinycc/lib/fp/arm/rp2350/d2f_subnormal.c.
    "20190901-1": "RP2350 DCP compare flushes subnormals: a subnormal double reads == 0.0",
    "ieee/cdivchkd": "RP2350 DCP compare flushes subnormals; vectors are full of subnormal doubles",
}

IGNORE_NATIVE_TARGET_SKIP_TESTS = os.environ.get("YASOS_SMOKE_RERUN_FAILED", "").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}

# Default user-process stack on the target, in KiB
# (CONFIG_PROCESS_DEFAULT_STACK_SIZE).
DEFAULT_TARGET_STACK_KIB = 32

# Tests whose on-target compile needs a deeper compiler-recursion stack than
# the 32 KiB process default. toybox `ulimit -s <KiB>` adjusts its PARENT's
# RLIMIT_STACK via prlimit — i.e. the test shell's — and execve reallocates
# the stack to the limit, so the raised limit applies to the tcc process the
# shell spawns for the compile. The shell's limit is restored in the same
# command line right after the compile. Keys match NATIVE_TARGET_SKIP_TESTS
# (directory-prefixed _test_key, or plain stem).
COMPILE_STACK_KIB_TESTS = {
    # ~40-level nested switch/if: recursive-descent parsing needs ~32 KiB of
    # stack even on the host, so the target's 32 KiB stack overflows (STKOF).
    "compile/pr113623": 64,
    # Huge main() with hundreds of varargs call expressions: recursive-descent
    # parsing overflows the target's default 32 KiB stack (host cross segfaults
    # at ulimit -s 32).  64 KiB still STKOFs on-device (larger native frames),
    # so raise to 128 KiB.
    "pr92904": 128,
    # Deeply-nested expressions/statements in a huge fn11(): native ARM frames
    # are much larger than host (host compiles fine at ulimit -s 32, but the
    # device overflows its default 32 KiB; 96/128 KiB compile on-device).
    "compile/pr82052": 128,
    # Deep expression recursion: host cross-tcc needs ~64 KiB for both.
    "unroll-1": 128,
    "builtins/strcat-chk": 128,
    # Still skipped (NATIVE_TARGET_SKIP_TESTS): limits-exprparen and
    # limits-structnest need ~8 MiB of compiler stack on the host, far above
    # the 1 MiB CONFIG_PROCESS_MAX_STACK_SIZE hard limit; limits-declparen
    # needs ~1 MiB, right at the cap and too heavy for the real target.
}


def _compile_stack_kib(test_path: Path) -> Optional[int]:
    """Per-test compile stack override (KiB), or None for the default."""
    value = COMPILE_STACK_KIB_TESTS.get(_gcc_conftest._test_key(test_path))
    if value is None:
        value = COMPILE_STACK_KIB_TESTS.get(test_path.stem)
    return value


# Tests whose on-target compile legitimately exceeds the 5 s COMPILE_TIMEOUT —
# large single-file sources that take real hardware longer than the serial
# wait. They fail deterministically with "Prompt not found" while the session
# log shows the compile completing fine moments later (the output is drained
# during cleanup). Measured on a 600 MHz RP2350; keep generous margin for
# lower clocks. Values are serial-timeout seconds for the compile wait (also
# raises the run-phase silence limit). Keys: directory-prefixed _test_key or
# plain stem for gcc-torture, full filename for tests2/ir_tests.
COMPILE_TIMEOUT_TESTS = {
    # gcc-torture compile: macro/argument-count stress files
    "limits-fnargs": 60,
    "limits-stringlit": 30,
    "pr34093": 30,
    "pr54713-3": 30,
    "pr54713-2": 30,
    "builtin-bitops-1": 160,
    "20040629-1": 60,
    "20040705-1": 60,
    "20040705-2": 60,
    "20040709-1": 60,
    "20040709-2": 60,
    "20040709-3": 60,
    "arith-rand-ll": 30,
    "pr107881-1": 60,
    "pr53645-2": 30,
    "pr92904": 120,
    "scal-to-vec1": 30,
    "scal-to-vec3": 15,
    "strlen-5": 30,
    "strlen-2": 20, 
    "strlen-4": 20,
    "920625-1": 30,
    "DFcmp": 30,
    "SIcmp": 30,
    "USIcmp": 30,
    "pr82052": 30,
    "20020108-1": 30,
    "990326-1": 30,
    "builtins/memset-chk": 30,
    "builtins/memcpy-chk": 15,
    "builtins/memmove-chk": 15,
    "builtins/mempcpy-chk": 15,
    "builtins/vsnprintf-chk": 10,
    "builtins/vsprintf-chk": 10,
    "builtins/snprintf-chk": 15,
    "builtins/sprintf-chk": 15,
    "builtins/stpcpy-chk": 15,
    "builtins/stpncpy-chk": 15,
    "builtins/strcat-chk": 15,
    "builtins/strcpy-chk": 15,
    "builtins/strncat-chk": 15,
    "builtins/strncpy-chk": 15,
    "memcpy-bi": 30,
    "misalign": 30,
    "pr53645": 30,
    "pr58574": 30,
    # ir_tests / tests2
    "mibench_rijndael.c": 60,
    "95_bitfields.c": 30,
    # The densest fuzz cases: ~2x the compile work of the next-slowest
    # ir_test at -O2, which puts them just past the 5 s default on the board.
    # Both compiles finish and exit 0 -- the harness only stopped listening
    # first, which surfaces as "Prompt not found" and reads like a miscompile.
    "219_fuzz_strd_spill_dryrun_offset.c": 30,
    "337_fuzz_genopif_double_round.c": 30,
    # Measured 5046 ms at -O2 on the 532 MHz rig -- essentially exactly the 5 s
    # default, so it passes on hardware (where the clock scaling widens the
    # window to 5.8 s) and trips under QEMU, whose defconfig carries no
    # cpu_clock_frequency_mhz and so gets the unscaled 5 s while one QEMU per
    # xdist worker oversubscribes the host.
    "252_fuzz_knownbits_imm_subword_sext.c": 30,
}


def _compile_timeout(test_path: Path) -> Optional[float]:
    """Per-test compile serial-timeout override (seconds), or None."""
    value = COMPILE_TIMEOUT_TESTS.get(_gcc_conftest._test_key(test_path))
    if value is None:
        value = COMPILE_TIMEOUT_TESTS.get(test_path.stem)
    return value


_DG_STACK_SIZE_PATTERN = re.compile(r'dg-require-stack-size\s+"([^"]+)"')
_DG_STACK_EXPR_PATTERN = re.compile(r"^[0-9a-fxA-FX\s*+()-]+$")


def _run_stack_kib(test_path: Path) -> Optional[int]:
    """Run-phase stack requirement (KiB), or None for the 32 KiB default.

    gcc-torture tests sized for hosts overflow the 32 KiB target stack with
    a genuine STKOF — QEMU only detects it when an interrupt stacks while SP
    is below PSPLIM, so without a raise these fail intermittently. The need
    is taken from the test's `dg-require-stack-size "<expr>"` directive when
    present, with a margin for libc/frame overhead.
    """
    try:
        text = test_path.read_text(errors="ignore")
    except OSError:
        return None
    match = _DG_STACK_SIZE_PATTERN.search(text)
    if not match:
        return None
    expr = match.group(1).strip()
    if not _DG_STACK_EXPR_PATTERN.match(expr):
        return None
    try:
        required_bytes = int(eval(expr, {"__builtins__": {}}, {}))  # arithmetic only
    except Exception:
        return None
    # Round up, double for -O0 frame bloat (tcc spills/temps can double the
    # declared need), plus a fixed libc/frame margin.
    kib = -(-required_bytes // 1024) * 2 + 64
    if kib <= DEFAULT_TARGET_STACK_KIB:
        return None
    return min(kib, 1024)  # CONFIG_PROCESS_MAX_STACK_SIZE hard cap


def _native_skip_reason(test_path: Path) -> Optional[str]:
    """Return skip reason if test should be skipped on native embedded target."""
    if IGNORE_NATIVE_TARGET_SKIP_TESTS:
        return None
    key = _gcc_conftest._test_key(test_path)
    if key in NATIVE_TARGET_SKIP_TESTS:
        return f"Native target skip: {NATIVE_TARGET_SKIP_TESTS[key]}"
    stem = test_path.stem
    if stem in NATIVE_TARGET_SKIP_TESTS:
        return f"Native target skip: {NATIVE_TARGET_SKIP_TESTS[stem]}"
    return None


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
    source_dir: str = ""  # Empty means use default (tests2)
    compile_only: bool = False
    expected_compile_failure: bool = False
    expected_error_patterns: tuple[str, ...] = ()
    skip_reason: Optional[str] = None
    xfail_reason: Optional[str] = None
    # Serial timeout (seconds) for this case's compile wait and run-phase
    # silence limit; None keeps the suite defaults.
    timeout: Optional[float] = None
    # Stack limit (KiB) raised around the on-target compile via `ulimit -s`;
    # None keeps the target's default process stack.
    compile_stack_kib: Optional[int] = None
    # Stack limit (KiB) raised around the whole test (incl. the run phase);
    # from LARGE_STACK_TESTS or the test's dg-require-stack-size directive.
    run_stack_kib: Optional[int] = None


REGISTERED_SINGLE_FILE_TESTS = [
    "90_min_repro.c",
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
    "40_stdio.c",
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
    "95_bitfields.c",
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
    "136_llong_diag.c",
    "136_llong_test.c",
    "137_llong_printf.c",
    "138_jmp_branch.c",
    "139_goto_cleanup_chain.c",
    "test_increment.c",
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
    # NOTE: 95_bitfields.c is NOT a -dt style tagged test. It's a self-including
    # file that compiles as a single unit. Moved to REGISTERED_SINGLE_FILE_TESTS.
    "96_nodata_wanted.c",
    "128_run_atexit.c",
]

TAGGED_EMPTY_EXPECTATION_COMPILE_ONLY_SOURCES = {
    "60_errors_and_warnings.c",
    "96_nodata_wanted.c",
}

SMOKE_DISABLED_TESTS = {
    "101_cleanup.c",
    "106_versym.c",
    "112_backtrace.c",
    "113_btdll.c",
    "114_bound_signal.c",
    "124_atomic_counter.c",
    "125_atomic_misc.c",
    "126_bound_global.c",
    "127_asm_goto.c",
    "73_arm64.c",
    "95_bitfields_ms.c",
    "98_al_ax_extend.c",
    "99_fastcall.c",
    "90_al_ax_extend.c",
    "117_builtins.c", # bounds check
}

FLOAT_TOLERANCE_TESTS = {
    "22_floating_point.c",
    "24_math_library.c",
    "95_bitfields.c",
    "70_floating_point_literals.c",
}

# Tests requiring a larger stack size (value in KB).
# 119_random_stuff.c has a 256KB struct on the stack passed by value.
LARGE_STACK_TESTS = {
    "119_random_stuff.c": 1024,
    # gcc-torture tests sized for hosts (STACK_SIZE undefined → big defaults):
    # genuine STKOF on the 32 KiB default process stack, not miscompiles.
    # QEMU only detects the violation when an interrupt stacks while SP is
    # below PSPLIM, so these failed intermittently (worse under -n N load).
    # (tests WITH a dg-require-stack-size directive are handled generically
    # by _run_stack_kib; only directive-less ones need entries here)
    "memcpy-1.c": 384,   # two 128 KiB (1<<17) local arrays
    "980605-1.c": 256,   # char ar[200000/2] = ~100 KiB
    "multi-ix.c": 192,   # 40 x int[500] = ~80 KiB
}

# Sources stay in the remote source tree; only compiler outputs use /tmp.

FLOAT_RELATIVE_TOLERANCE = 1e-4


GCC_EXECUTE_PERSISTENT_OUTPUT_TESTS = {
    "941202-1",
    "pr22061-1",
    "ieee/pr28634",
}


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


def _read_stack_size(session):
    """Read the current stack size limit (in KB) from the target."""
    session.write_command("ulimit -s")
    lines = session.wait_for_prompt_except_logs()
    for line in lines:
        stripped = line.strip()
        if stripped.isdigit():
            return int(stripped)
    return None


def _set_stack_size(session, size_kb):
    """Set the stack size limit (in KB) on the target."""
    session.write_command(f"ulimit -s {size_kb}")
    session.wait_for_prompt_except_logs()


RETURNS_PATTERN = re.compile(r"^\[returns (\d+)\]$")
TAG_PATTERN = re.compile(r"^\[([a-zA-Z_][a-zA-Z0-9_]*(?:=[^\]]+)?)\]$")
SHA256_LINE_PATTERN = re.compile(r"^(?P<digest>[0-9a-f]{64})(?:\s+.+)?$", re.IGNORECASE)
LOCAL_INCLUDE_PATTERN = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.MULTILINE)
EXIT_MARKER_PREFIX = "__EXIT_STATUS__:"
COMPILE_MARKER_PREFIX = "__COMPILE_STATUS__:"
temp_source_reuse_plan_key = pytest.StashKey()


@dataclass(frozen=True)
class TempSourceReusePlan:
    first_users: frozenset[str]
    last_users: frozenset[str]


def build_tcc_test_cases():
    test_cases = []

    for source_name in REGISTERED_SINGLE_FILE_TESTS:
        if source_name in SMOKE_DISABLED_TESTS:
            continue
        for test_id, cflags in _opt_level_variants(source_name):
            test_cases.append(TccTestCase(test_id=test_id, name=source_name, sources=(source_name,),
                                          cflags=cflags,
                                          timeout=COMPILE_TIMEOUT_TESTS.get(source_name)))

    for source_name, args in REGISTERED_TESTS_WITH_ARGS:
        if source_name in SMOKE_DISABLED_TESTS:
            continue
        for test_id, cflags in _opt_level_variants(source_name):
            test_cases.append(TccTestCase(test_id=test_id, name=source_name, sources=(source_name,),
                                          cflags=cflags, args=args))

    for test_case in REGISTERED_MULTI_FILE_TESTS:
        if any(source_name in SMOKE_DISABLED_TESTS for source_name in test_case.sources):
            continue
        for test_id, cflags in _opt_level_variants(test_case.test_id, test_case.cflags):
            test_cases.append(replace(test_case, test_id=test_id, cflags=cflags))

    for source_name in REGISTERED_TAGGED_TEST_FILES:
        if source_name in SMOKE_DISABLED_TESTS:
            continue
        tagged_expectations = parse_tagged_expect_file(source_name)
        for tag, expectation in tagged_expectations.items():
            for test_id, cflags in _opt_level_variants(f"{source_name}[{tag}]", (f"-D{tag}",)):
                test_cases.append(
                    TccTestCase(
                        test_id=test_id,
                        name=source_name,
                        sources=(source_name,),
                        cflags=cflags,
                        expected_lines=tuple(expectation["lines"]),
                        expected_exit_code=expectation["exit_code"],
                        expected_compile_failure=expectation["expected_compile_failure"],
                        expected_error_patterns=tuple(expectation["expected_error_patterns"]),
                        compile_only=expectation.get("compile_only", False),
                    )
                )

    return test_cases


# IR tests - simple single-file tests with .expect files
IR_TESTS_DISABLED = {
    # Tests that may need special handling or are known to fail
    "test_gcc_torture_ir.py",  # Not a C test file
    "test_qemu.py",  # Not a C test file
    "test_stack_frames.py",  # Not a C test file
}

# Known self-host miscompiles: these compile correctly with the gcc-built cross
# (so the host-cross IR harness passes) but the self-hosted device tcc
# miscompiles them at the listed optimization level.  Keyed by (filename,
# opt_level) so only the affected variant is xfailed; remove the entry once the
# underlying compiler bug is fixed (an XPASS then flags it for cleanup).
IR_TESTS_XFAIL = {
    # (empty) 183_selfhost_inline_accumulate at -O1 was fixed by the
    # ra_safe_loop_phi_coalesce cur-outlives-partner guard (tinycc c1847440).
}

IR_TESTS_FLOAT_TOLERANCE = {
    "70_float_simple.c",
    "71_double_simple.c",
    "71_float_noprintf.c",
    "72_float_result.c",
    "73_double_printf.c",
    "73_float_ops.c",
    "74_double_assign_print.c",
    "test_double_printf_ops.c",
    "test_double_printf_literals.c",
    "test_double_printf_mixed.c",
    "test_float_simple_calc.c",
    "test_float_math_loop.c",
    "test_double_arith.c",
    "test_double_arith2.c",
    "test_aeabi.c",
    "test_aeabi_dadd.c",
    "test_aeabi_dcmp.c",
    "test_aeabi_dconv.c",
    "test_aeabi_ddiv.c",
    "test_aeabi_dmul.c",
    "test_aeabi_dneg.c",
    "test_aeabi_dsub.c",
    "test_aeabi_double_all.c",
    "test_aeabi_dmul_bits.c",
    "test_f2d_bits.c",
    "test_double_bits.c",
    "test_double_bytes.c",
    "test_double_printfonly.c",
    "test_double_simple.c",
    "test_double_simple_printf.c",
    "test_double_noprint.c",
    "test_dcmp.c",
    "test_ddiv_debug.c",
    "test_ddiv_lib.c",
    "test_ddiv_trace.c",
    "test_ddiv_trace2.c",
    "test_debug_double.c",
    "test_div_simple.c",
    "test_dmul_debug.c",
    "test_dmul_loop.c",
    "test_dmul_trace.c",
    "test_double_cleanup.c",
    "test_fp_offset_cache.c",
    "test_fp_cache_callee_saved.c",
    "150_builtin_fp.c",
    "141_builtin_signbit.c",
    "141_builtin_signbit_limitation.c",
    "142_builtin_copysign.c",
    "170_nan_comparison.c",
}


def build_ir_test_cases():
    """Build test cases from ir_tests directory.

    Each .c file with a corresponding .expect file becomes a test case.
    """
    test_cases = []

    if not os.path.exists(ir_tests_path):
        return test_cases

    for filename in sorted(os.listdir(ir_tests_path)):
        if not filename.endswith(".c"):
            continue
        if filename in IR_TESTS_DISABLED:
            continue

        # Check if there's a corresponding .expect file
        expect_file = filename.replace(".c", ".expect")
        expect_path = os.path.join(ir_tests_path, expect_file)
        if not os.path.exists(expect_path):
            continue

        for test_id, cflags in _opt_level_variants(f"ir_tests/{filename}"):
            opt_level = cflags[0] if cflags else "-O0"
            test_cases.append(TccTestCase(
                test_id=test_id,
                name=filename,
                sources=(filename,),
                cflags=cflags,
                source_dir=ir_tests_path,
                skip_reason=_native_skip_reason(Path(ir_tests_path) / filename),
                xfail_reason=IR_TESTS_XFAIL.get((filename, opt_level)),
                timeout=COMPILE_TIMEOUT_TESTS.get(filename),
            ))

    return test_cases


def _split_cflags(flag_string):
    if not flag_string:
        return ()
    return tuple(shlex.split(flag_string))


def _gcc_execute_test_id(source_path, opt_level):
    execute_root = Path(gcc_execute_path).resolve()
    source = Path(source_path)
    try:
        relative = source.relative_to(execute_root)
    except ValueError:
        relative = source.name
    stem = str(relative.with_suffix("")) if isinstance(relative, Path) else str(relative)
    return f"gcc_execute/{stem}[{opt_level}]"


def _gcc_compile_test_id(source_path, opt_level):
    stem = Path(source_path).stem
    return f"gcc_compile/{stem}[{opt_level}]"


def build_gcc_execute_test_cases():
    test_cases = []
    execute_root = Path(gcc_execute_path).resolve()

    for gcc_case in discover_gcc_execute_tests():
        relative_source = gcc_case.source.relative_to(execute_root)
        sources = [relative_source.as_posix()]
        sources.extend(extra_source.relative_to(execute_root).as_posix() for extra_source in gcc_case.extra_sources)

        skip_reason = should_skip_gcc_test(gcc_case.source) or _native_skip_reason(gcc_case.source)
        xfail_reason = is_xfail_test(gcc_case.source)

        for opt_level in GCC_OPT_LEVELS:
            opt_xfail_reason = xfail_reason
            if opt_level == "-O1":
                opt_xfail_reason = opt_xfail_reason or is_xfail_o1_test(gcc_case.source)

            cflags = (opt_level,) + _split_cflags(gcc_case.dg_options)
            test_cases.append(
                TccTestCase(
                    test_id=_gcc_execute_test_id(gcc_case.source, opt_level),
                    name=relative_source.as_posix(),
                    sources=tuple(sources),
                    cflags=cflags,
                    expected_lines=(),
                    expected_exit_code=gcc_case.expected_exit_code,
                    source_dir=gcc_execute_path,
                    skip_reason=skip_reason,
                    xfail_reason=opt_xfail_reason,
                    timeout=_compile_timeout(gcc_case.source),
                    compile_stack_kib=_compile_stack_kib(gcc_case.source),
                    run_stack_kib=LARGE_STACK_TESTS.get(relative_source.name)
                    or _run_stack_kib(gcc_case.source),
                )
            )

    return test_cases


def build_gcc_compile_test_cases():
    test_cases = []
    compile_root = Path(gcc_compile_path).resolve()

    for gcc_case in discover_gcc_compile_tests():
        relative_source = gcc_case.source.relative_to(compile_root)
        skip_reason = should_skip_gcc_test(gcc_case.source) or _native_skip_reason(gcc_case.source)
        xfail_reason = is_xfail_test(gcc_case.source)

        for opt_level in GCC_OPT_LEVELS:
            cflags = (opt_level,) + _split_cflags(gcc_case.dg_options)
            test_cases.append(
                TccTestCase(
                    test_id=_gcc_compile_test_id(gcc_case.source, opt_level),
                    name=relative_source.as_posix(),
                    sources=(relative_source.as_posix(),),
                    cflags=cflags,
                    expected_lines=(),
                    expected_exit_code=gcc_case.expected_exit_code,
                    source_dir=gcc_compile_path,
                    compile_only=True,
                    expected_compile_failure=gcc_case.expected_compile_failure,
                    expected_error_patterns=tuple(gcc_case.expected_error_patterns),
                    skip_reason=skip_reason,
                    xfail_reason=xfail_reason,
                    timeout=_compile_timeout(gcc_case.source),
                    compile_stack_kib=_compile_stack_kib(gcc_case.source),
                )
            )

    return test_cases


def load_expect_file(source_name, source_dir=None):
    base_path = source_dir if source_dir else path
    expect = os.path.join(base_path, source_name.replace(".c", ".expect"))
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
    source_basename = os.path.basename(source_name)
    with open(expect, "r") as handle:
        for raw_line in handle:
            stripped_line = raw_line.strip()
            if not stripped_line:
                continue

            tag_match = TAG_PATTERN.match(stripped_line)
            if tag_match:
                current_tag = tag_match.group(1)
                tags[current_tag] = {
                    "lines": [],
                    "exit_code": 0,
                    "expected_compile_failure": False,
                    "expected_error_patterns": [],
                }
                continue

            returns_match = RETURNS_PATTERN.match(stripped_line)
            if returns_match and current_tag is not None:
                tags[current_tag]["exit_code"] = int(returns_match.group(1))
                continue

            if current_tag is not None:
                tags[current_tag]["lines"].append(stripped_line)
                if source_basename in stripped_line and ": error:" in stripped_line:
                    tags[current_tag]["expected_compile_failure"] = True
                    tags[current_tag]["expected_error_patterns"].append(re.escape(stripped_line))

    # Mark tests as compile-only when ALL expected output lines are compiler
    # diagnostics (contain the source filename). These have no main() and must
    # be compiled with -c to avoid a spurious "undefined symbol 'main'" linker error.
    #
    # Some tagged sources mix runnable tests with compile-only variants that
    # intentionally produce no diagnostics. Keep the override source-based so
    # those empty tagged expectations still compile with -c, without forcing the
    # whole file into compile-only mode.
    for tag, expectation in tags.items():
        lines = expectation["lines"]
        if (
            source_basename in TAGGED_EMPTY_EXPECTATION_COMPILE_ONLY_SOURCES and not lines
        ):
            expectation["compile_only"] = True
        elif lines and all(source_basename in line for line in lines):
            expectation["compile_only"] = True
        else:
            expectation["compile_only"] = False

    return tags




def _resolve_remote_source_root(relative_path, source_dir=None):
    """Resolve the remote source root based on relative path and source directory.

    For ir_tests, the source_dir will be set to ir_tests_path, and we map to REMOTE_IR_TESTS_DIR.
    """
    normalized_parts = PurePosixPath(relative_path).parts
    if len(normalized_parts) >= 2 and normalized_parts[0] == "..":
        if normalized_parts[1] == "tests2":
            return REMOTE_TESTS2_DIR, posixpath.join(*normalized_parts[2:]) if len(normalized_parts) > 2 else ""
        if normalized_parts[1] == "ir_tests":
            return REMOTE_IR_TESTS_DIR, posixpath.join(*normalized_parts[2:]) if len(normalized_parts) > 2 else ""

    # If source_dir is ir_tests_path, use REMOTE_IR_TESTS_DIR
    if source_dir == ir_tests_path:
        return REMOTE_IR_TESTS_DIR, relative_path

    if source_dir == gcc_compile_path:
        return REMOTE_GCC_COMPILE_DIR, relative_path

    if source_dir == gcc_execute_path:
        return REMOTE_GCC_EXECUTE_DIR, relative_path

    return REMOTE_TESTS2_DIR, relative_path


# ── Source sharding ─────────────────────────────────────────────────────────
#
# FAT resolves a path by walking the directory linearly, and the walk is the
# dominant cost of open(): measured on the rig, 6.6 ms in the 1685-entry
# gcc execute corpus against 0.22 ms in a two-entry directory, and the same
# 6.6 ms on a *second* open of the same file -- one walk reads ~81 KiB through
# a 16 KiB sector cache, so it evicts itself and no cache the kernel can afford
# will hold it. The only lever left is holding fewer entries per directory.
#
# So each source goes into a bucket subdirectory named for a hash of its
# filename, giving ~50-60 entries per directory instead of ~1700.
#
# Except when it cannot: some sources include a sibling by name
# (95_bitfields_ms.c includes "95_bitfields.c", 20040709-3.c includes
# "20040709-2.c"), some include a shared header (gcc_tmpnam.h), and some reach
# out of the directory entirely ("../../gcc.dg/..."). Moving any of those
# breaks the include. A file is therefore only sharded when it includes nothing
# by quoted path and nothing includes it by name; everything else stays where
# it is, together, and keeps working. That leaves 1752 of 1912 gcc execute
# files and 1985 of 2003 gcc compile files shardable.
SHARD_SOURCES = os.environ.get(
    "YASOS_SMOKE_SHARD_SOURCES", "1"
).strip().lower() not in {"0", "false", "no", "off"}
SHARD_BUCKETS = 32

# Directories under a corpus root that hold build output rather than test
# sources; scanning them for includes costs seconds and finds nothing relevant.
_SHARD_SCAN_SKIP_DIRS = {"qemu", "build", "libs", "newlib_build", ".git"}
_QUOTED_INCLUDE_RE = re.compile(r'#\s*include\s+"([^"]+)"')
_shardable_cache: dict[str, frozenset] = {}


def _shardable_names(local_dir):
    """Basenames under *local_dir* that may be moved into a bucket directory."""
    cached = _shardable_cache.get(local_dir)
    if cached is not None:
        return cached

    sources = []
    for root, dirs, files in os.walk(local_dir):
        dirs[:] = [d for d in dirs if d not in _SHARD_SCAN_SKIP_DIRS]
        for filename in files:
            if filename.endswith((".c", ".h", ".i")):
                sources.append(os.path.join(root, filename))

    includes_something = set()
    included_by_someone = set()
    for source in sources:
        try:
            with open(source, "r", encoding="utf-8", errors="ignore") as handle:
                text = handle.read()
        except OSError:
            # Unreadable means unknown, and unknown means leave it alone.
            includes_something.add(os.path.basename(source))
            continue
        for match in _QUOTED_INCLUDE_RE.finditer(text):
            includes_something.add(os.path.basename(source))
            included_by_someone.add(posixpath.basename(match.group(1)))

    result = frozenset(
        os.path.basename(source)
        for source in sources
        if os.path.basename(source) not in includes_something
        and os.path.basename(source) not in included_by_someone
    )
    _shardable_cache[local_dir] = result
    return result


def _local_corpus_dir(remote_root):
    return {
        REMOTE_TESTS2_DIR: path,
        REMOTE_IR_TESTS_DIR: ir_tests_path,
        REMOTE_GCC_COMPILE_DIR: gcc_compile_path,
        REMOTE_GCC_EXECUTE_DIR: gcc_execute_path,
    }.get(remote_root)


def _shard_bucket(filename):
    return "%02x" % (zlib.crc32(filename.encode("utf-8")) % SHARD_BUCKETS)


def _sharded_relative_path(remote_root, remote_relative_path):
    if not SHARD_SOURCES or not remote_relative_path:
        return remote_relative_path
    local_dir = _local_corpus_dir(remote_root)
    if local_dir is None:
        return remote_relative_path
    parent, _, filename = remote_relative_path.rpartition("/")
    if not filename or filename not in _shardable_names(local_dir):
        return remote_relative_path
    bucket = _shard_bucket(filename)
    return posixpath.join(parent, bucket, filename) if parent else posixpath.join(bucket, filename)


def remote_source_path(relative_path, source_dir=None):
    remote_root, remote_relative_path = _resolve_remote_source_root(relative_path, source_dir)
    return posixpath.normpath(
        posixpath.join(remote_root, _sharded_relative_path(remote_root, remote_relative_path))
    )


def remote_output_dir(testcase=None):
    if testcase is not None and testcase.source_dir == gcc_execute_path:
        testcase_key = str(Path(testcase.name).with_suffix(""))
        if testcase_key in GCC_EXECUTE_PERSISTENT_OUTPUT_TESTS:
            return REMOTE_PERSISTENT_OUTPUT_DIR
    return REMOTE_OUTPUT_DIR


def _enter_output_dir(session, output_dir):
    """cd into the compiler-output directory for a test case.

    The default output dir is /tmp, which always exists, so we just cd into it
    — no per-test mkdir round-trip. The source-tree directories are created on
    demand when their files are uploaded (see ``upload``), so they don't need a
    per-test mkdir either. Only the non-default (persistent) output dir may be
    missing, so it gets a one-shot ``mkdir -p`` folded into the same command.

    We then wait for the shell prompt before returning. ``write_command``
    returns as soon as it sees the command *echo*, not the prompt, so without
    this the next command (the source ``sha256sum``, a long line) would be blasted
    while the shell is still scheduling back in and printing its prompt — RX IRQs
    masked, the UART FIFO not drained, and the tail of the burst dropped. Parking
    the device at an idle prompt first is exactly the state the later ``tcc`` line
    enjoys (it follows the hash's prompt-wait) and never truncates.
    """
    with record("setup_ms"):
        if output_dir == REMOTE_OUTPUT_DIR:
            session.write_command("cd " + shlex.quote(output_dir))
        else:
            session.write_command(
                "mkdir -p " + shlex.quote(output_dir)
                + " && cd " + shlex.quote(output_dir)
            )
        session.wait_for_prompt_except_logs()


def remote_output_path(filename, testcase=None):
    return posixpath.normpath(posixpath.join(remote_output_dir(testcase), filename))


# --------------------------------------------------------------------------
# Source manifest
#
# Every test verifies its sources on the device before compiling, which costs a
# toybox spawn plus a serial round trip per source -- about 4500 of them in a
# full run -- even though the device copies almost never change: /root/ci lives
# on the SD card, so uploaded sources survive reboots and reflashes.
#
# ``Session.confirmed_uploads`` already skips that re-check for a source seen
# earlier in the SAME pytest session. The manifest replaces the per-test check
# outright, because the suite knows its whole corpus up front and has no reason
# to learn the device's state one test at a time:
#
#   * the map is PREBUILT on the host -- every source every collected test case
#     could upload, hashed in one pass (``_corpus_source_hashes``);
#   * it lives in ``.cache/smoke_source_manifest.json`` (the remote-runner rsync
#     excludes ``.cache/``, so it survives on the runner), with a witness token
#     holding the sha256 OF THAT MAP at ``/root/ci/sources/.smoke_manifest_id``;
#   * one ``cat`` of the token at the first upload of a session says whether the
#     device is still in the state the map describes. If it is, the whole map
#     seeds ``confirmed_uploads`` and no test hashes anything.
#
# Getting the first map is the only interesting part, and there are four ways:
#
#   * default (push) -- upload whatever the device is not already witnessed to
#     hold, in one batched zmodem session, and then seed from what we just
#     wrote. Establishes rather than discovers, so it is the only mode that also
#     handles a target holding nothing, and it costs the same whether the run
#     that follows reaches the end or is Ctrl-C'd after ten tests;
#   * YASOS_SMOKE_SOURCE_MANIFEST_PUSH=0 -- the lazy path this used to default
#     to: the tests verify their own sources as they reach them, exactly as
#     before the manifest existed, and each one is banked. One full run leaves a
#     complete map -- but only a full one, which is why it is no longer the
#     default;
#   * YASOS_SMOKE_SOURCE_MANIFEST_TRUST=1 -- seed the whole prebuilt corpus at
#     once, no device work, for when the device is known to be in sync;
#   * YASOS_SMOKE_SOURCE_MANIFEST_CHECK=1 -- send the map over and have the
#     device confirm it with a single ``sha256sum -c``. Verified rather than
#     assumed, but it moves half a megabyte over the UART; on a link that takes
#     CRC retries on most subpackets that costs more than it saves, which is why
#     it is opt-in.
#
# Asking for TRUST or CHECK stands the default push down; an explicit
# YASOS_SMOKE_SOURCE_MANIFEST_PUSH= setting wins over both.
#
# Anything that goes wrong -- token missing (fresh or wiped filesystem, QEMU
# relaunch), token stale, map unreadable, a source the device could not confirm
# -- falls back to per-file verification, which uploads what is actually
# missing. Set YASOS_SMOKE_SOURCE_MANIFEST=0 to disable the mechanism entirely.
# --------------------------------------------------------------------------

# Under pytest-xdist every worker drives its own target (run_qemu_smoke.sh
# starts one QEMU per worker), so each one keeps its own map rather than racing
# the others for a shared file that could only ever describe one of the devices.
_XDIST_WORKER = os.environ.get("PYTEST_XDIST_WORKER", "").strip()
SOURCE_MANIFEST_PATH = REPO_ROOT / ".cache" / (
    f"smoke_source_manifest.{_XDIST_WORKER}.json" if _XDIST_WORKER
    else "smoke_source_manifest.json"
)
REMOTE_MANIFEST_ID_PATH = posixpath.join(REMOTE_SOURCES_ROOT, ".smoke_manifest_id")
REMOTE_MANIFEST_CHECK_PATH = posixpath.join(REMOTE_SOURCES_ROOT, ".smoke_manifest")
SOURCE_MANIFEST_VERSION = 1
SOURCE_MANIFEST_ENABLED = os.environ.get(
    "YASOS_SMOKE_SOURCE_MANIFEST", "1"
).strip().lower() not in {"0", "false", "no", "off"}
TRUTHY_ENVIRONMENT_VALUES = {"1", "true", "yes", "on"}


def source_manifest_bootstrap_flags(environ):
    """Which bootstrap a run uses: ``(trust, check, push)``.

    Push is what a plain run does, because it is the only bootstrap that
    establishes the corpus rather than discovering it: it works on a target
    holding nothing (fresh SD card, QEMU), and it costs the same whether the run
    that follows reaches the end or is Ctrl-C'd after ten tests. The lazy path
    it replaced only left a map behind when a run reached the end, so every
    interrupted run handed the next one the same several thousand per-source
    round trips.

    ``YASOS_SMOKE_SOURCE_MANIFEST_PUSH=0`` asks for that lazy path back; asking
    for either of the other bootstraps stands the push down, since only one of
    them can establish the map and an explicit request should win over a
    default.
    """
    def requested(name):
        return environ.get(name, "").strip().lower() in TRUTHY_ENVIRONMENT_VALUES

    # Seed the whole prebuilt corpus without asking the device to confirm it.
    # The fast way to bootstrap a map when you know the device is in sync.
    trust = requested("YASOS_SMOKE_SOURCE_MANIFEST_TRUST")
    # Bootstrap the map by sending the corpus over and having the device check
    # it. OFF by default: the map is half a megabyte, and on a link that takes
    # CRC retries on most subpackets (as the 2026-07-31 rig did) that transfer
    # costs more than the per-file verification it replaces -- and it would be
    # paid at the start of every run that has no map yet.
    check = requested("YASOS_SMOKE_SOURCE_MANIFEST_CHECK")
    # Bootstrap the map by pushing the sources themselves: whatever the device
    # is not already known to hold goes over in one batched zmodem session,
    # after which the host knows the device's state because it just wrote it.
    push_setting = environ.get("YASOS_SMOKE_SOURCE_MANIFEST_PUSH", "").strip().lower()
    push = (
        push_setting in TRUTHY_ENVIRONMENT_VALUES if push_setting
        else not (trust or check)
    )
    return trust, check, push


(
    SOURCE_MANIFEST_TRUST,
    SOURCE_MANIFEST_CHECK,
    SOURCE_MANIFEST_PUSH,
) = source_manifest_bootstrap_flags(os.environ)
# The corpus check hashes every source on the device, so it needs a longer
# silence window than an ordinary command -- though only between output lines,
# since `_read_until` measures idle time rather than a total deadline.
SOURCE_MANIFEST_CHECK_TIMEOUT = float(
    os.environ.get("YASOS_SMOKE_SOURCE_MANIFEST_CHECK_TIMEOUT", "300")
)
# What `sha256sum -c` prints for a file that matches (the alternative is
# "<path>: FAILED", or an open error when the file is not there at all).
MANIFEST_CHECK_OK_SUFFIX = ": OK"
# How many corpus sources the map may fail to cover before it is worth sending
# the whole corpus over and re-checking it on the device. Below this, letting
# the per-test path verify the stragglers is cheaper than the check -- and the
# next flush folds them into the map anyway, so the gap closes on its own.
SOURCE_MANIFEST_RECHECK_THRESHOLD = int(
    os.environ.get("YASOS_SMOKE_SOURCE_MANIFEST_RECHECK_THRESHOLD", "1024")
)
# Newly verified sources needed before the map is rewritten mid-run. Only a run
# that grows the map pays these writes at all; the point of not writing on every
# test is that each write is a device round trip, and the point of keeping the
# interval short is that runs get interrupted -- and when the interruption is a
# Ctrl-C in the remote runner it takes the ssh session, and with it pytest's
# whole shutdown path, so these periodic writes are the only thing that banks
# the sources verified so far.
SOURCE_MANIFEST_FLUSH_EVERY = int(
    os.environ.get("YASOS_SMOKE_SOURCE_MANIFEST_FLUSH_EVERY", "32")
)
# Seconds between push progress lines. On a terminal they redraw in place, so
# this only paces the refresh; through the remote runner's pipe each one is a
# line in the log, which is what keeps this from being sub-second.
SOURCE_MANIFEST_PROGRESS_INTERVAL = float(
    os.environ.get("YASOS_SMOKE_SOURCE_MANIFEST_PROGRESS_INTERVAL", "2")
)
# tcc could not open an input: "file 'x.c' not found", "include file 'y.h' not
# found".
MISSING_INPUT_PATTERN = re.compile(r"\bfile '(?P<name>[^']*)' not found")

# Seeding state, tagged with the ``confirmed_uploads`` generation it describes
# so a mid-run target reset (which clears that cache) re-seeds rather than
# leaving the rest of the run unseeded.
_source_manifest_state = {
    "generation": None,  # confirmed_uploads generation this state describes
    "digest": None,      # digest currently recorded on host and device
    "count": 0,          # entries covered by that digest
}


def _source_manifest_digest(entries):
    payload = json.dumps(entries, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _read_source_manifest():
    try:
        raw = SOURCE_MANIFEST_PATH.read_text(encoding="utf-8")
    except OSError:
        return {}
    try:
        document = json.loads(raw)
    except ValueError:
        return {}
    if not isinstance(document, dict):
        return {}
    if document.get("version") != SOURCE_MANIFEST_VERSION:
        return {}
    entries = document.get("entries")
    if not isinstance(entries, dict):
        return {}
    return {
        str(remote_path): str(digest).lower()
        for remote_path, digest in entries.items()
        if SHA256_LINE_PATTERN.match(str(digest))
    }


def _write_source_manifest(entries):
    SOURCE_MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = SOURCE_MANIFEST_PATH.with_name(SOURCE_MANIFEST_PATH.name + ".tmp")
    temporary_path.write_text(
        json.dumps(
            {"version": SOURCE_MANIFEST_VERSION, "entries": entries},
            sort_keys=True,
            indent=0,
        ),
        encoding="utf-8",
    )
    temporary_path.replace(SOURCE_MANIFEST_PATH)


def _read_remote_manifest_id(session):
    session.write_command("cat " + shlex.quote(REMOTE_MANIFEST_ID_PATH))
    for line in session.wait_for_prompt_except_logs(timeout=COMPILE_TIMEOUT):
        match = SHA256_LINE_PATTERN.match(line.strip())
        if match is not None:
            return match.group("digest").lower()
    return None


# Whether the line currently on screen is a transient progress line waiting to
# be overwritten (terminals only), so the next ordinary message can close it
# instead of appending to it.
_manifest_progress_line_open = [False]


def _manifest_progress(message, transient=False):
    """Say what the manifest is doing, straight to the console.

    Establishing the manifest is the one part of a run that can sit silent for
    minutes -- several megabytes of sources going out, or the device hashing
    several thousand files. The remote runner invokes pytest with ``-s``, so a
    plain print lands on the operator's screen; a logger call would only reach
    the captured log.

    A *transient* message redraws in place on a terminal. Anywhere else -- and
    the remote runner is anywhere else, since it pipes pytest's output rather
    than giving it a tty -- it is an ordinary line, because a log full of
    carriage returns is one unreadable line rather than a progress bar.
    """
    if transient and sys.stdout.isatty():
        print(f"\r  manifest: {message}\x1b[K", end="", flush=True)
        _manifest_progress_line_open[0] = True
        return
    if _manifest_progress_line_open[0]:
        print(flush=True)  # close the in-place line before writing over it
        _manifest_progress_line_open[0] = False
    print(f"  manifest: {message}", flush=True)


def _format_duration(seconds):
    """m:ss for a wait the operator is watching, or ``--:--`` when unknown."""
    if seconds is None or seconds < 0 or seconds != seconds:  # NaN-safe
        return "--:--"
    seconds = int(seconds)
    return f"{seconds // 60}:{seconds % 60:02d}"


def _format_push_progress(done, total, sent, total_bytes, elapsed, width=24):
    """One line of push progress: bar, counts, throughput and what is left.

    Throughput is what tells the operator whether a push is progressing or the
    link has gone quiet, and it is the number the whole bootstrap trade-off
    rests on -- so it is on screen rather than only in the summary.
    """
    fraction = (sent / total_bytes) if total_bytes else 1.0
    fraction = min(max(fraction, 0.0), 1.0)
    filled = int(round(fraction * width))
    bar = "#" * filled + "-" * (width - filled)
    rate = (sent / elapsed) if elapsed > 0 else 0.0
    remaining = (total_bytes - sent) / rate if rate > 0 else None
    return (
        f"pushing [{bar}] {done}/{total} sources  "
        f"{sent // 1024}/{total_bytes // 1024} KiB  "
        f"{rate / 1024:.0f} KiB/s  eta {_format_duration(remaining)}"
    )


def _iter_corpus_sources():
    """Walk every source the suite could upload, straight from the host tree.

    Yields ``(remote_path, local_path)``, keyed by remote path so the sources
    shared by the -O0/-O1/-O2 variants of a test -- and by the many tagged
    variants of one file -- are visited once. The include scan is skipped for a
    case whose own sources are all known, since the same sources always pull in
    the same headers.
    """
    seen = set()
    for cases in (
        test_cases, ir_test_cases, gcc_compile_test_cases, gcc_execute_test_cases
    ):
        for testcase in cases:
            source_dir = testcase.source_dir if testcase.source_dir else None
            upload_entries = _iter_testcase_upload_entries(testcase)
            if all(
                remote_source_path(remote_name, source_dir) in seen
                for _, remote_name in upload_entries
            ):
                continue
            upload_entries.extend(_discover_local_dependencies(upload_entries))
            for local_path, remote_name in upload_entries:
                remote_path = remote_source_path(remote_name, source_dir)
                if remote_path in seen or not Path(local_path).is_file():
                    continue
                seen.add(remote_path)
                yield remote_path, local_path


def _corpus_source_hashes():
    """The whole corpus as remote path -> sha256 of the host copy."""
    return {
        remote_path: sha256_file(str(local_path))
        for remote_path, local_path in _iter_corpus_sources()
    }


def _corpus_source_files():
    """The whole corpus as remote path -> host path, for the push bootstrap."""
    return {
        remote_path: str(local_path)
        for remote_path, local_path in _iter_corpus_sources()
    }


def _push_corpus_to_device(session, corpus, witnessed):
    """Upload every source the device is not already known to hold.

    The alternative bootstraps ask the device what it has; this one makes it so.
    That is the cheaper direction: the corpus is 4.13 MiB of mostly sub-kilobyte
    files, while the map of hashes the device would need in order to check
    itself is 511 KiB -- an eighth of just sending the sources -- and it would
    still have to read and hash all 4.13 MiB off the SD card afterwards. It is
    also the only bootstrap that works on a target holding nothing at all (a
    fresh card, or QEMU), where a check can only report that everything is
    missing.

    Returns the set actually established, or None if the transfer failed and
    the caller should fall back to per-test verification.
    """
    local_paths = _corpus_source_files()
    outstanding = sorted(
        remote_path for remote_path, digest in corpus.items()
        if witnessed.get(remote_path) != digest and remote_path in local_paths
    )
    if not outstanding:
        return dict(corpus)

    transfers = [(local_paths[remote_path], remote_path) for remote_path in outstanding]
    total_bytes = sum(
        os.path.getsize(local_path) for local_path, _ in transfers
    )
    _manifest_progress(
        f"pushing {len(transfers)} of {len(corpus)} sources "
        f"({total_bytes // 1024} KiB) in one batch"
    )

    # Paced by the clock rather than by a file count: the corpus runs from
    # empty files to 400 KiB ones, so "every N files" would be a burst of lines
    # through the small ones and silence through the big ones.
    started = time.monotonic()
    last_report = [started]

    def _on_progress(done, total, sent):
        now = time.monotonic()
        if now - last_report[0] < SOURCE_MANIFEST_PROGRESS_INTERVAL:
            return
        last_report[0] = now
        _manifest_progress(
            _format_push_progress(done, total, sent, total_bytes, now - started),
            transient=True,
        )

    try:
        sent_bytes = serial_send_files(session, transfers, on_progress=_on_progress)
    except Exception as error:  # transfer failures must not fail the run
        logger.warning("source manifest: push failed (%s)", error)
        _manifest_progress(f"push failed ({error}), verifying per test instead")
        return None

    elapsed = time.monotonic() - started
    rate = (sent_bytes / elapsed / 1024) if elapsed > 0 else 0.0
    _manifest_progress(
        f"pushed {len(transfers)} sources ({sent_bytes // 1024} KiB) "
        f"in {_format_duration(elapsed)} at {rate:.0f} KiB/s"
    )
    return dict(corpus)


def _verify_corpus_on_device(session, corpus):
    """Have the device check the whole corpus against our hashes, in one go.

    Returns the subset the device confirmed byte-for-byte. ``sha256sum -c``
    reports a verdict per line rather than one status for the lot (``-s``), for
    two reasons: a source that disagrees costs only itself instead of the whole
    map, and the steady trickle of verdicts keeps the read alive -- the silent
    form would have the device say nothing at all while it hashes several
    thousand files off the SD card, which is exactly what an idle timeout is
    meant to treat as a hang.
    """
    check_path = SOURCE_MANIFEST_PATH.with_name(SOURCE_MANIFEST_PATH.name + ".check")
    check_path.parent.mkdir(parents=True, exist_ok=True)
    check_path.write_text(
        "".join(
            f"{digest}  {remote_path}\n" for remote_path, digest in sorted(corpus.items())
        ),
        encoding="utf-8",
    )

    session.write_command("mkdir -p " + shlex.quote(REMOTE_SOURCES_ROOT))
    session.wait_for_prompt_except_logs()

    uploaded_percent = [0]

    def _on_upload(sent, total):
        percent = 100 * sent // total
        if percent < uploaded_percent[0]:
            return
        uploaded_percent[0] = percent + 5
        _manifest_progress(
            f"uploading {len(corpus)} hashes, {sent // 1024}/{total // 1024} KiB ({percent}%)"
        )

    # Far bigger than an ordinary source upload (half a megabyte of hashes), so
    # the device gets longer than the default to answer between blocks.
    serial_send_file(
        session, str(check_path), REMOTE_MANIFEST_CHECK_PATH,
        timeout=30.0, on_progress=_on_upload,
    )

    checked = [0, 500]

    def _on_verdict(_line):
        checked[0] += 1
        if checked[0] >= checked[1]:
            checked[1] = checked[0] + 500
            _manifest_progress(f"device checked {checked[0]}/{len(corpus)} sources")
        return False  # never abort: we want every verdict

    session.write_command("sha256sum -c " + shlex.quote(REMOTE_MANIFEST_CHECK_PATH))
    lines, _ = session.wait_for_prompt_streaming(
        _on_verdict, timeout=SOURCE_MANIFEST_CHECK_TIMEOUT
    )

    verified = {}
    for line in lines:
        if not line.endswith(MANIFEST_CHECK_OK_SUFFIX):
            continue  # "...: FAILED", or an open error; leave it to the per-test path
        digest = corpus.get(line[: -len(MANIFEST_CHECK_OK_SUFFIX)])
        if digest is not None:
            verified[line[: -len(MANIFEST_CHECK_OK_SUFFIX)]] = digest
    return verified


def ensure_source_manifest_seeded(session):
    """Confirm the whole corpus up front so no test hashes its own sources."""
    confirmed = getattr(session, "confirmed_uploads", None)
    if not SOURCE_MANIFEST_ENABLED or confirmed is None:
        return
    generation = getattr(session, "confirmed_uploads_generation", 0)
    if _source_manifest_state["generation"] == generation:
        return

    corpus = _corpus_source_hashes()
    entries = _read_source_manifest()

    # Steady state: a map that still covers (nearly all of) the corpus, and a
    # device that still witnesses that map. One round trip, no corpus check.
    # Sources the map has gone stale on are seeded anyway and cost nothing:
    # upload_testcase compares against the CURRENT local hash, so a changed file
    # misses the fast path and gets verified and re-uploaded as before.
    uncovered = sum(
        1 for path, digest in corpus.items() if entries.get(path) != digest
    )
    # What the device is known to hold, once it has vouched for the map. Push
    # mode reads the token even when the map has fallen a long way behind,
    # because knowing the covered part is what lets it send only the rest.
    witnessed = {}
    if entries and (
        uncovered <= SOURCE_MANIFEST_RECHECK_THRESHOLD or SOURCE_MANIFEST_PUSH
    ):
        digest = _source_manifest_digest(entries)
        # Read before the state update below: if the device cannot answer, the
        # generation stays unset and the next upload retries instead of silently
        # giving up on the manifest for the whole run.
        if _read_remote_manifest_id(session) == digest:
            witnessed = entries
            # Nothing left to establish -- or, without push, nothing worth
            # establishing: verifying the few stragglers per test is cheaper
            # than a re-establish, and the next flush folds them in.
            if uncovered == 0 or not SOURCE_MANIFEST_PUSH:
                confirmed.update(entries)
                _source_manifest_state.update(
                    generation=generation, digest=digest, count=len(entries)
                )
                logger.info("source manifest: seeded %d sources", len(entries))
                return

    _source_manifest_state.update(generation=generation, digest=None, count=0)
    if not corpus:
        return

    started = time.monotonic()
    if SOURCE_MANIFEST_TRUST:
        _manifest_progress(f"seeding {len(corpus)} host sources unchecked")
        verified = dict(corpus)
    elif SOURCE_MANIFEST_PUSH:
        verified = _push_corpus_to_device(session, corpus, witnessed)
        if verified is None:
            return
        _manifest_progress(f"device holds all {len(verified)} sources")
    elif SOURCE_MANIFEST_CHECK:
        _manifest_progress(f"establishing {len(corpus)} sources on the device")
        verified = _verify_corpus_on_device(session, corpus)
        # Timed because what this costs on hardware -- the device hashing
        # several thousand files off the SD card -- is the only reason the
        # bootstrap is opt-in, and it has never been measured.
        _manifest_progress(
            f"device confirmed {len(verified)} of {len(corpus)} sources "
            f"in {time.monotonic() - started:.1f}s"
        )
    else:
        # No map to seed from and the push stood down: let the tests verify
        # their own sources as they reach them, exactly as before the manifest
        # existed. Each one gets banked, so a full run leaves a complete map and
        # every run after it starts from the fast path -- but only a run that
        # reaches the end, which is why this is no longer what a plain run does.
        _manifest_progress(
            f"no map for {len(corpus)} sources yet, verifying per test "
            f"(the push bootstrap is off; unset "
            f"YASOS_SMOKE_SOURCE_MANIFEST_PUSH to establish them in one batch)"
        )
        return
    if not verified:
        return

    confirmed.update(verified)
    flush_source_manifest(session, force=True)


def flush_source_manifest(session, force=False):
    """Record the confirmed set on the host and re-witness it on the device."""
    confirmed = getattr(session, "confirmed_uploads", None)
    if not SOURCE_MANIFEST_ENABLED or not confirmed:
        return False
    grown_by = len(confirmed) - _source_manifest_state["count"]
    if not force and grown_by < SOURCE_MANIFEST_FLUSH_EVERY:
        return False

    entries = dict(confirmed)
    digest = _source_manifest_digest(entries)
    if digest == _source_manifest_state["digest"]:
        return False

    # Host map first: a token that outlives the map it vouches for would be a
    # lie, while a map that outlives its token merely stops matching and costs
    # the next run a re-verification.
    _write_source_manifest(entries)
    session.write_command(
        "echo " + shlex.quote(digest) + " > " + shlex.quote(REMOTE_MANIFEST_ID_PATH)
    )
    session.wait_for_prompt_except_logs(timeout=COMPILE_TIMEOUT)
    _source_manifest_state.update(digest=digest, count=len(entries))
    logger.info("source manifest: recorded %d verified sources", len(entries))
    return True


def _names_a_confirmed_source(compile_output, confirmed):
    """Did tcc fail to open a file the confirmed set claims to have put there?

    A source we passed on the command line is named by its full remote path. An
    include is named the way the source spelled it, so it is matched by
    basename against the confirmed set -- which also keeps a header the upload
    scan never discovered (a harness gap, not a stale manifest) from being
    blamed on the manifest.
    """
    basenames = {posixpath.basename(remote_path) for remote_path in confirmed or {}}
    for match in MISSING_INPUT_PATTERN.finditer(compile_output):
        name = match.group("name")
        if name.startswith(REMOTE_SOURCES_ROOT + "/"):
            return True
        if posixpath.basename(name) in basenames:
            return True
    return False


def note_compile_failure_for_manifest(session, compile_output):
    """Drop the manifest when tcc could not open one of its inputs.

    The manifest vouches for device copies it never looks at, so the one way it
    can be wrong is a source that disappeared behind our back. tcc says exactly
    that, and it is the signal to stop trusting the map: forget the confirmed
    set so the rerun re-hashes and re-uploads, and delete the host map so the
    next run starts from a clean slate.
    """
    if not SOURCE_MANIFEST_ENABLED:
        return
    confirmed = getattr(session, "confirmed_uploads", None)
    if not _names_a_confirmed_source(compile_output, confirmed):
        return

    if confirmed is not None:
        confirmed.clear()
    _source_manifest_state.update(generation=None, digest=None, count=0)
    try:
        SOURCE_MANIFEST_PATH.unlink()
    except OSError:
        pass
    logger.warning(
        "source manifest: tcc could not open an input, dropping the manifest"
    )


def get_remote_hash(remote_path, session):
    with record("hash_ms"):
        return _get_remote_hash_uncounted(remote_path, session)


def _get_remote_hash_uncounted(remote_path, session):
    session.write_command("sha256sum " + shlex.quote(remote_path))
    data = session.wait_for_prompt_except_logs(timeout=COMPILE_TIMEOUT)
    if not data:
        return None

    first_line = data[0].strip()
    if "No such file or directory" in first_line:
        return None

    hash_match = SHA256_LINE_PATTERN.match(first_line)
    if hash_match is None:
        return None

    return hash_match.group("digest").lower()


def upload_testcase(local_path, remote_relative_path, session, source_dir=None):
    remote_path = remote_source_path(remote_relative_path, source_dir)
    remote_dir = posixpath.dirname(remote_path)
    local_hash = sha256_file(local_path)

    # Fast path: this exact content was already uploaded-and-verified to this
    # exact remote path during this session. The device copy can only change if
    # we re-upload it (we don't here) or the target is reset (which clears this
    # cache in Session.reset_target). Skipping the device-side sha256sum removes
    # a toybox spawn + serial round-trip per source per test — and the redundant
    # re-hash of the same file across the -O0/-O1/-O2 reruns.
    confirmed = getattr(session, "confirmed_uploads", None)
    if confirmed is not None and confirmed.get(remote_path) == local_hash:
        return "cached"

    remote_hash = get_remote_hash(remote_path, session)
    upload_state = "checking hash"

    if remote_hash is None:
        upload_state = "uploading"
        session.write_command("mkdir -p " + shlex.quote(remote_dir))
        session.wait_for_prompt_except_logs()
        serial_send_file(session, local_path, remote_path)
        remote_hash = get_remote_hash(remote_path, session)
        assert remote_hash is not None, "file upload failed, missing remote hash"

    if local_hash != remote_hash:
        upload_state = "re-uploading"
        session.write_command("rm " + shlex.quote(remote_path))
        session.wait_for_prompt_except_logs()
        serial_send_file(session, local_path, remote_path)

        remote_hash = get_remote_hash(remote_path, session)
        assert remote_hash is not None, "file upload failed, missing remote hash"
        assert local_hash == remote_hash, "file upload failed, hash mismatch"

    # Remote now matches local; remember it so later tests this session take the
    # fast path above instead of re-hashing on the device.
    if confirmed is not None:
        confirmed[remote_path] = local_hash

    if upload_state == "checking hash":
        return "cached"
    return upload_state


def _iter_testcase_upload_entries(testcase):
    base_path = Path(testcase.source_dir if testcase.source_dir else path)
    entries = []
    for source_name in testcase.sources:
        entries.append((base_path / source_name, source_name))
    for local_name, remote_name in testcase.support_files:
        entries.append((base_path / local_name, remote_name))
    return entries


def _discover_local_dependencies(upload_entries):
    discovered = []
    queued = list(upload_entries)
    seen_local_paths = set()
    seen_remote_paths = {posixpath.normpath(remote_name) for _, remote_name in upload_entries}

    while queued:
        local_path, remote_name = queued.pop()
        resolved_local_path = Path(local_path).resolve()
        if resolved_local_path in seen_local_paths or not resolved_local_path.is_file():
            continue
        seen_local_paths.add(resolved_local_path)

        try:
            content = resolved_local_path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue

        remote_parent = posixpath.dirname(posixpath.normpath(remote_name))
        for include_name in LOCAL_INCLUDE_PATTERN.findall(content):
            dependency_local = (resolved_local_path.parent / include_name).resolve()
            if not dependency_local.is_file():
                continue

            dependency_remote = posixpath.normpath(
                posixpath.join(remote_parent, include_name)
            )
            if dependency_remote in seen_remote_paths:
                continue

            seen_remote_paths.add(dependency_remote)
            dependency_entry = (dependency_local, dependency_remote)
            discovered.append(dependency_entry)
            queued.append(dependency_entry)

    return discovered

def upload_test_sources(testcase, session):
    ensure_source_manifest_seeded(session)

    upload_states = []
    upload_entries = _iter_testcase_upload_entries(testcase)
    upload_entries.extend(_discover_local_dependencies(upload_entries))

    for local_path, remote_name in upload_entries:
        upload_states.append(
            upload_testcase(
                str(local_path),
                remote_name,
                session,
                testcase.source_dir if testcase.source_dir else None,
            )
        )

    flush_source_manifest(session)

    if not upload_states:
        return "cached"
    if any(state == "re-uploading" for state in upload_states):
        return "re-uploading"
    if any(state == "uploading" for state in upload_states):
        return "uploading"
    return "cached"


def get_testcase_binary_name(testcase):
    binary_name = testcase.name.replace(".c", "")
    return binary_name.replace("/", "__").replace("[", "_").replace("]", "_")


def _shared_temp_source_path(testcase):
    if not _should_copy_source_to_tmp(testcase):
        return None

    remote_path = remote_source_path(
        testcase.sources[0], testcase.source_dir if testcase.source_dir else None
    )
    source_digest = hashlib.sha256(remote_path.encode("utf-8")).hexdigest()[:12]
    source_basename = os.path.basename(testcase.sources[0])
    return posixpath.join(
        remote_output_dir(testcase), f"shared_source__{source_digest}__{source_basename}"
    )


def _build_temp_source_reuse_marks(item_entries):
    first_users = set()
    last_users = set()
    users_by_source = {}

    for item_id, testcase in item_entries:
        temp_source_path = _shared_temp_source_path(testcase)
        if temp_source_path is None:
            continue
        users_by_source.setdefault(temp_source_path, []).append(item_id)

    for item_ids in users_by_source.values():
        first_users.add(item_ids[0])
        last_users.add(item_ids[-1])

    return TempSourceReusePlan(
        first_users=frozenset(first_users),
        last_users=frozenset(last_users),
    )


def _build_temp_source_reuse_plan(items):
    item_entries = []
    for item in items:
        callspec = getattr(item, "callspec", None)
        if callspec is None:
            continue
        testcase = callspec.params.get("testcase")
        if not isinstance(testcase, TccTestCase):
            continue
        item_entries.append((item.nodeid, testcase))
    return _build_temp_source_reuse_marks(item_entries)


def get_temp_source_reuse_plan(pytest_session):
    plan = pytest_session.stash.get(temp_source_reuse_plan_key, None)
    if plan is None:
        plan = _build_temp_source_reuse_plan(pytest_session.items)
        pytest_session.stash[temp_source_reuse_plan_key] = plan
    return plan


def _should_copy_source_to_tmp(testcase):
    _ = testcase
    return False


def _prepare_compile_source_paths(testcase, session, current_item_id=None, temp_source_plan=None):
    temp_source_path = _shared_temp_source_path(testcase)
    if temp_source_path is None:
        source_paths = [
            remote_source_path(source_name, testcase.source_dir if testcase.source_dir else None)
            for source_name in testcase.sources
        ]
        return source_paths, []

    remote_source = remote_source_path(
        testcase.sources[0], testcase.source_dir if testcase.source_dir else None
    )
    should_copy = temp_source_plan is None or current_item_id in temp_source_plan.first_users
    if should_copy:
        session.write_command(
            f"cp {shlex.quote(remote_source)} {shlex.quote(temp_source_path)}"
        )
        session.wait_for_prompt_except_logs()

    cleanup_paths = []
    should_cleanup = temp_source_plan is None or current_item_id in temp_source_plan.last_users
    if should_cleanup:
        cleanup_paths.append(temp_source_path)

    return [temp_source_path], cleanup_paths


def compile_testcase(testcase, session, timing=None, current_item_id=None, temp_source_plan=None):
    filename_without_extension = get_testcase_binary_name(testcase)
    output_name = filename_without_extension + (".o" if testcase.compile_only else "")
    output_binary = remote_output_path(output_name, testcase)

    # Expected-compile-failure tests never produce the output binary (the
    # compile bails with an error), so there is nothing to remove. Skip queuing
    # it for cleanup — `rm -f` on the nonexistent path returns "Invalid
    # argument" on the target VFS instead of silently succeeding.
    cleanup_paths = [] if testcase.expected_compile_failure else [output_binary]
    source_paths, temp_cleanup_paths = _prepare_compile_source_paths(
        testcase,
        session,
        current_item_id=current_item_id,
        temp_source_plan=temp_source_plan,
    )
    cleanup_paths.extend(temp_cleanup_paths)

    source_args = " ".join(shlex.quote(source_path) for source_path in source_paths)
    flag_args = " ".join(shlex.quote(flag) for flag in testcase.cflags)
    compile_args = " ".join(arg for arg in (source_args, flag_args) if arg)
    compile_mode_flag = "-c " if testcase.compile_only or testcase.expected_compile_failure else ""
    bench_flag = "-bench " if profiling_enabled() else ""
    extra_cflags = " ".join(shlex.quote(f) for f in EXTRA_TCC_CFLAGS)
    if extra_cflags:
        extra_cflags += " "

    stack_raise = ""
    stack_restore = ""
    if testcase.compile_stack_kib:
        stack_raise = f"ulimit -s {testcase.compile_stack_kib}; "
        stack_restore = f"ulimit -s {DEFAULT_TARGET_STACK_KIB}; "

    try:
        session.write_command(
            f"{stack_raise}"
            f"{os.environ.get('YASOS_TCC_ENV_PREFIX', '')}"
            f"tcc {bench_flag}{compile_mode_flag}{extra_cflags}{compile_args} -o {shlex.quote(output_binary)}; "
            f"compile_status=$?; "
            f"{stack_restore}"
            f"if [ $compile_status -eq 0 ] && [ ! -e {shlex.quote(output_binary)} ]; then compile_status=254; fi; "
            f"echo {COMPILE_MARKER_PREFIX}$compile_status"
        )
        old_timeout = session.serial.timeout
        session.serial.timeout = testcase.timeout or max(COMPILE_TIMEOUT, old_timeout)
        _t_compile = start_timer()
        try:
            compile_lines = session.wait_for_prompt_except_logs()
        finally:
            if timing is not None:
                timing.compile_ms = elapsed_ms(_t_compile)
            session.serial.timeout = old_timeout

        compile_status = None
        filtered_compile_lines = []
        profile_lines = []
        for line in compile_lines:
            if line.startswith(COMPILE_MARKER_PREFIX):
                compile_status = int(line[len(COMPILE_MARKER_PREFIX):])
                continue
            if line.startswith("# "):
                profile_lines.append(line)
                continue
            filtered_compile_lines.append(line)

        if profile_lines:
            # The device-side breakdown of the compile window (loader, syscall
            # and IO time) rides along on the same `# ` lines as the bench
            # output, so it is attached whenever tcc printed it.
            if timing is not None:
                attach_compile_profile(timing, profile_lines)
            if profiling_enabled():
                record_profile(testcase.test_id, profile_lines)

        assert compile_status is not None, f"missing compile status in output: {compile_lines}"

        expected_lines = testcase.expected_lines
        expected_exit_code = testcase.expected_exit_code
        if expected_lines is None:
            expected_lines, expected_exit_code = load_expect_file(testcase.name, testcase.source_dir if testcase.source_dir else None)

        source_basename = os.path.basename(testcase.name)
        compile_expected_lines = []
        runtime_expected_lines = []
        for expected_line in expected_lines:
            if source_basename in expected_line:
                compile_expected_lines.append(expected_line)
            else:
                runtime_expected_lines.append(expected_line)

        compile_output = "\n".join(filtered_compile_lines)
        if compile_status != 0 and not testcase.expected_compile_failure:
            # Expected-failure cases are excluded because some of them test the
            # missing-include diagnostic on purpose.
            note_compile_failure_for_manifest(session, compile_output)

        for expected_line in compile_expected_lines:
            assert expected_line in compile_output, f"expected compile-time line '{expected_line}' in '{filtered_compile_lines}'"

        if testcase.expected_compile_failure:
            assert compile_status != 0, "compilation unexpectedly succeeded for expected-failure test"

            missing_patterns = []
            for pattern in sorted({pattern for pattern in testcase.expected_error_patterns if pattern}):
                if re.search(pattern, compile_output, re.MULTILINE) is None:
                    missing_patterns.append(pattern)

            assert not missing_patterns, (
                "compilation failed, but expected diagnostics were missing:\n"
                + "\n".join(repr(pattern) for pattern in missing_patterns)
                + "\n\ncompiler output:\n"
                + compile_output
            )
            return

        assert compile_status == 0, f"compilation failed (exit {compile_status}):\n{compile_output}"

        if testcase.compile_only:
            return

        quoted_args = " ".join(shlex.quote(argument) for argument in testcase.args)
        run_command = shlex.quote(output_binary)
        if quoted_args:
            run_command = f"{run_command} {quoted_args}"

        use_float_tolerance = testcase.name in FLOAT_TOLERANCE_TESTS or testcase.name in IR_TESTS_FLOAT_TOLERANCE

        # Validate stdout as it streams in so a miscompile that prints a wrong
        # value — or runs away printing forever, like a broken do/while loop —
        # fails on the offending line instead of blocking until the serial read
        # times out (which buffers megabytes of garbage first).
        run_state = {"index": 0, "reason": None}

        def _validate_run_line(line):
            if line.startswith(EXIT_MARKER_PREFIX):
                return False
            index = run_state["index"]
            if index < len(runtime_expected_lines):
                expected_line = runtime_expected_lines[index]
                run_state["index"] = index + 1
                if use_float_tolerance:
                    matched = lines_match_with_float_tolerance(
                        expected_line, line, FLOAT_RELATIVE_TOLERANCE
                    )
                else:
                    matched = expected_line in line
                if not matched:
                    run_state["reason"] = (
                        f"expected '{expected_line}' in output, got '{line}'"
                    )
                    return True
                return False
            # Every expected line already matched; any further output before the
            # exit marker means the program produced more than expected. Only
            # treat this as authoritative when the test fully specifies its
            # output (runtime_expected_lines non-empty) — gcc-torture cases only
            # check the exit code and may legitimately print extra lines.
            if runtime_expected_lines:
                run_state["reason"] = (
                    f"unexpected extra output '{line}' after "
                    f"{len(runtime_expected_lines)} expected line(s)"
                )
                return True
            return False

        session.write_command(f"{run_command}; echo {EXIT_MARKER_PREFIX}$?")
        _t_execute = start_timer()
        data_lines, run_aborted = session.wait_for_prompt_streaming(
            _validate_run_line, timeout=testcase.timeout
        )
        if timing is not None:
            timing.execute_ms = elapsed_ms(_t_execute)
            attach_loader_timing(timing, getattr(session, "log_path", ""), output_binary)

        assert not run_aborted, run_state["reason"]

        actual_exit_code = None
        filtered_lines = []
        for line in data_lines:
            if line.startswith(EXIT_MARKER_PREFIX):
                actual_exit_code = int(line[len(EXIT_MARKER_PREFIX):])
                continue
            filtered_lines.append(line)

        assert actual_exit_code is not None, f"missing exit status in output: {data_lines}"
        for index, expected_line in enumerate(runtime_expected_lines):
            actual_line = filtered_lines[index].strip()
            if use_float_tolerance:
                assert lines_match_with_float_tolerance(expected_line, actual_line, FLOAT_RELATIVE_TOLERANCE), \
                    f"expected '{expected_line}' to match '{actual_line}' within tolerance {FLOAT_RELATIVE_TOLERANCE}"
            else:
                assert expected_line in actual_line, f"expected '{expected_line}' in '{filtered_lines}'"
        assert actual_exit_code == expected_exit_code, f"expected exit code {expected_exit_code}, got {actual_exit_code}"
    finally:
        # Before cleanup, so the `rm` below -- harness work, and an expensive
        # syscall on FAT -- is not charged to the test.
        if timing is not None:
            attach_kernel_profile(
                timing,
                getattr(session, "log_path", ""),
                {"compile": COMPILE_MARKER_PREFIX, "execute": EXIT_MARKER_PREFIX},
            )
        # Skip cleanup when the target is being reset (e.g. we aborted early on a
        # runaway program or it crashed): the foreground job is still running, so
        # the rm command would never echo back and the reset wipes /tmp anyway.
        needs_reset = getattr(session, "target_needs_reset", False)
        if cleanup_paths and not needs_reset:
            # This cleanup fires immediately after a memory-heavy compile, while
            # the device is still tearing down the tcc process (releasing its
            # large GOT/heap). On big test cases (e.g. pr54713-3, kernel_used
            # ~70k) that teardown can push the echo of this command past the
            # default 1 s serial timeout, tripping a false "Prompt not found"
            # desync even though the compile itself passed. Give the echo the
            # same generous budget the compile read got.
            with record("cleanup_ms"), session.timeout(max(COMPILE_TIMEOUT, session.serial.timeout)):
                session.write_command(
                    "rm -f " + " ".join(shlex.quote(cleanup_path) for cleanup_path in cleanup_paths)
                )
                session.wait_for_prompt_except_logs()

path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../libs/tinycc/tests/tests2"))
ir_tests_path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../libs/tinycc/tests/ir_tests"))
gcc_testsuite_path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../libs/tinycc/tests/gcctestsuite"))
gcc_compile_path = os.path.join(gcc_testsuite_path, "gcc-testsuite/gcc/testsuite/gcc.c-torture/compile")
gcc_execute_path = os.path.join(gcc_testsuite_path, "gcc-testsuite/gcc/testsuite/gcc.c-torture/execute")

test_cases = build_tcc_test_cases()
test_cases = sorted(test_cases, key=lambda testcase: testcase.test_id)

ir_test_cases = build_ir_test_cases()
ir_test_cases = sorted(ir_test_cases, key=lambda testcase: testcase.test_id)

gcc_compile_test_cases = []
gcc_execute_test_cases = []
if ENABLE_GCC_TORTURE_SMOKE and GCC_TORTURE_PATH.exists():
    gcc_compile_test_cases = sorted(build_gcc_compile_test_cases(), key=lambda testcase: testcase.test_id)
    gcc_execute_test_cases = sorted(build_gcc_execute_test_cases(), key=lambda testcase: testcase.test_id)


def _failure_is_real(session, exc):
    """Decide whether a testcase failure is a genuine compiler/device fault or
    a transient serial glitch.

    Real failures are not retried:
      * a device crash (HardFault / kernel halt) — flagged on the session via
        ``Session.target_crashed`` from the serial crash markers;
      * a genuine compile-time out-of-memory — tcc prints ``memory full``.

    Everything else (most commonly a UART truncation/desync where the stream is
    cut mid-command and the prompt is never seen) is treated as transient.
    """
    if getattr(session, "target_crashed", False):
        return True, "device crash"
    if "memory full" in str(exc).lower():
        return True, "compile-time OOM ('memory full')"
    return False, None


def _resync_prompt_for_rerun(session):
    """Best-effort recovery of a clean shell prompt before a rerun.

    First try a gentle recovery: drain stale serial output and nudge the shell
    with a newline. The common transient failure is a mid-command UART
    truncation where the trailing newline still arrived, so the bad command
    already ran and the shell is back at a prompt -- no interrupt is needed.

    If the gentle recovery fails, a foreground job is most likely still running
    -- the dominant case being a compile that overran its serial-read deadline
    (tcc is silent while it works, so the gentle 2 s nudges expired before it
    finished). Its late output -- the warnings, the __COMPILE_STATUS__ line and
    the prompt -- is still draining and would corrupt the rerun's commands (the
    "ompile_status=254; fi" -> "sh: syntax error: fi" desync seen in the logs),
    so before escalating we passively wait for that in-flight job to land on a
    prompt. Only if THAT also fails (a job is genuinely stuck) do we fall back
    to Ctrl-C (\\x03), which avoids injecting a spurious ETX/^C into the serial
    stream -- and into the per-test logs and the live console -- on every retry.
    """
    for _ in range(3):
        try:
            if session._try_recover_prompt():
                return True
        except Exception:
            break
    # Gentle recovery couldn't get a prompt: a foreground job is probably still
    # running and swallowing our nudges. Wait (idle seconds) for it to finish
    # and emit its prompt before touching the line. The byte-level read returns
    # the instant the prompt arrives, so this only burns the full window when
    # the line is genuinely dead -- in which case the Ctrl-C below is warranted.
    try:
        settled = session._read_until(session.prompt, timeout=RERUN_SETTLE_TIMEOUT)
        if settled.endswith(session.prompt):
            return True
    except Exception:
        pass
    # Still stuck: interrupt the job, then retry.
    try:
        session.serial.write(b"\x03")  # kill a stuck/runaway foreground job
    except Exception:
        pass
    for _ in range(3):
        try:
            if session._try_recover_prompt():
                return True
        except Exception:
            break
    return False


def run_case_with_optional_rerun(testcase, session, request, temp_source_plan, progress, timing):
    """Upload + compile/run a testcase, rerunning ONCE on a transient failure.

    A device crash or a compile-time ``memory full`` is a real failure and is
    reported immediately. Any other failure is assumed to be a transient serial
    glitch and is retried a single time on a resynced prompt; if the retry also
    fails it is reported as-is (a deterministic miscompile fails both times).
    """
    max_attempts = 2
    for attempt in range(1, max_attempts + 1):
        try:
            upload_state = upload_test_sources(testcase, session)
            progress.update(upload_state)
            progress.update("compiling" if attempt == 1 else "rerunning")
            compile_testcase(
                testcase,
                session,
                timing=timing,
                current_item_id=request.node.nodeid,
                temp_source_plan=temp_source_plan,
            )
            return
        except Exception as exc:
            real, reason = _failure_is_real(session, exc)
            if real or attempt == max_attempts:
                if real:
                    logger.warning(
                        "%s: real failure (%s), not rerunning", testcase.test_id, reason
                    )
                raise
            first_line = (str(exc).strip().splitlines() or [type(exc).__name__])[0]
            logger.warning(
                "%s: transient failure (attempt %d/%d), rerunning once: %s",
                testcase.test_id, attempt, max_attempts, first_line,
            )
            progress.update("retry")
            _resync_prompt_for_rerun(session)



@pytest.mark.flaky(reruns=0)
@pytest.mark.parametrize('testcase', test_cases, ids=[testcase.test_id for testcase in test_cases])
def test_run_tcc_test_suite(request, testcase):
    session = request.node.stash[session_key]
    # Opened before the first device round trip so `record` blocks below land on
    # this case; the session's own prompt resync happened in pytest_runtest_setup.
    timing = begin_case(testcase.test_id)
    add_timing("setup_ms", getattr(session, "prepare_ms", 0.0))
    temp_source_plan = get_temp_source_reuse_plan(request.session)
    output_dir = remote_output_dir(testcase)
    _enter_output_dir(session, output_dir)

    progress = ProgressLine(testcase.test_id)

    original_stack_size = None
    required_stack_kb = LARGE_STACK_TESTS.get(testcase.name)
    if required_stack_kb is not None:
        with record("setup_ms"):
            original_stack_size = _read_stack_size(session)
            logger.info(
                "Stack size for %s: current=%s, required=%s",
                testcase.name, original_stack_size, required_stack_kb,
            )
            _set_stack_size(session, required_stack_kb)

    try:
        run_case_with_optional_rerun(
            testcase, session, request, temp_source_plan, progress, timing
        )
    except Exception:
        progress.finish("failed")
        raise
    finally:
        if original_stack_size is not None:
            with record("cleanup_ms"):
                _set_stack_size(session, original_stack_size)
        end_case()
        timing_results.append(timing)
    progress.finish("ok")


@pytest.mark.flaky(reruns=0)
@pytest.mark.parametrize('testcase', ir_test_cases, ids=[testcase.test_id for testcase in ir_test_cases])
def test_run_ir_test_suite(request, testcase):
    """Run ir_tests from tinycc/tests/ir_tests directory."""
    session = request.node.stash[session_key]
    temp_source_plan = get_temp_source_reuse_plan(request.session)
    if testcase.skip_reason:
        pytest.skip(testcase.skip_reason)
    if testcase.xfail_reason:
        pytest.xfail(testcase.xfail_reason)
    # Opened before the first device round trip so `record` blocks below land on
    # this case; the session's own prompt resync happened in pytest_runtest_setup.
    timing = begin_case(testcase.test_id)
    add_timing("setup_ms", getattr(session, "prepare_ms", 0.0))
    output_dir = remote_output_dir(testcase)
    _enter_output_dir(session, output_dir)

    progress = ProgressLine(testcase.test_id)

    try:
        run_case_with_optional_rerun(
            testcase, session, request, temp_source_plan, progress, timing
        )
    except Exception:
        progress.finish("failed")
        raise
    finally:
        end_case()
        timing_results.append(timing)
    progress.finish("ok")


@pytest.mark.flaky(reruns=0)
@pytest.mark.gcc_torture
@pytest.mark.gcc_compile
@pytest.mark.parametrize('testcase', gcc_compile_test_cases, ids=[testcase.test_id for testcase in gcc_compile_test_cases])
def test_run_gcc_compile_torture_suite(request, testcase):
    session = request.node.stash[session_key]
    temp_source_plan = get_temp_source_reuse_plan(request.session)
    if testcase.skip_reason:
        pytest.skip(testcase.skip_reason)
    if testcase.xfail_reason:
        pytest.xfail(testcase.xfail_reason)

    # Opened before the first device round trip so `record` blocks below land on
    # this case; the session's own prompt resync happened in pytest_runtest_setup.
    timing = begin_case(testcase.test_id)
    add_timing("setup_ms", getattr(session, "prepare_ms", 0.0))
    output_dir = remote_output_dir(testcase)
    _enter_output_dir(session, output_dir)

    progress = ProgressLine(testcase.test_id)

    try:
        run_case_with_optional_rerun(
            testcase, session, request, temp_source_plan, progress, timing
        )
    except Exception:
        progress.finish("failed")
        raise
    finally:
        end_case()
        timing_results.append(timing)
    progress.finish("ok")


@pytest.mark.flaky(reruns=0)
@pytest.mark.gcc_torture
@pytest.mark.gcc_execute
@pytest.mark.parametrize('testcase', gcc_execute_test_cases, ids=[testcase.test_id for testcase in gcc_execute_test_cases])
def test_run_gcc_execute_torture_suite(request, testcase):
    session = request.node.stash[session_key]
    temp_source_plan = get_temp_source_reuse_plan(request.session)
    if testcase.skip_reason:
        pytest.skip(testcase.skip_reason)
    if testcase.xfail_reason:
        pytest.xfail(testcase.xfail_reason)

    # Opened before the first device round trip so `record` blocks below land on
    # this case; the session's own prompt resync happened in pytest_runtest_setup.
    timing = begin_case(testcase.test_id)
    add_timing("setup_ms", getattr(session, "prepare_ms", 0.0))
    output_dir = remote_output_dir(testcase)
    _enter_output_dir(session, output_dir)

    progress = ProgressLine(testcase.test_id)

    # Tests whose RUN phase needs more than the 32 KiB default process stack
    # (large main() locals, STACK_SIZE-sized arrays). The violation is only
    # detected when an interrupt stacks while SP is below PSPLIM, so without
    # the raise these fail intermittently (more often under parallel load).
    original_stack_size = None
    required_stack_kb = testcase.run_stack_kib
    if required_stack_kb is not None:
        with record("setup_ms"):
            original_stack_size = _read_stack_size(session)
            _set_stack_size(session, required_stack_kb)

    try:
        run_case_with_optional_rerun(
            testcase, session, request, temp_source_plan, progress, timing
        )
    except Exception:
        progress.finish("failed")
        raise
    finally:
        if original_stack_size is not None:
            with record("cleanup_ms"):
                _set_stack_size(session, original_stack_size)
        end_case()
        timing_results.append(timing)
    progress.finish("ok")


if not ENABLE_GCC_TORTURE_SMOKE:
    @pytest.mark.gcc_torture
    @pytest.mark.gcc_compile
    @pytest.mark.skip(reason="Set YASOS_SMOKE_ENABLE_GCC_TORTURE=1 to run GCC torture smoke tests")
    def test_run_gcc_compile_torture_suite_disabled():
        pass


    @pytest.mark.gcc_torture
    @pytest.mark.gcc_execute
    @pytest.mark.skip(reason="Set YASOS_SMOKE_ENABLE_GCC_TORTURE=1 to run GCC torture smoke tests")
    def test_run_gcc_execute_torture_suite_disabled():
        pass


if ENABLE_GCC_TORTURE_SMOKE and not GCC_TORTURE_PATH.exists():
    @pytest.mark.gcc_torture
    @pytest.mark.gcc_compile
    @pytest.mark.skip(reason="GCC torture tests not found under libs/tinycc/tests/gcctestsuite")
    def test_run_gcc_compile_torture_suite_missing():
        pass


    @pytest.mark.gcc_torture
    @pytest.mark.gcc_execute
    @pytest.mark.skip(reason="GCC torture tests not found under libs/tinycc/tests/gcctestsuite")
    def test_run_gcc_execute_torture_suite_missing():
        pass
