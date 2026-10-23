"""Check the fixed thunk contract and replay through Zig C and the kernel tcc."""

import os
from pathlib import Path
import re
import struct
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("zig_opt", ["ReleaseFast", "ReleaseSafe"])
def test_thunk_replay_avoids_runtime_division_and_copy_calls(tmp_path, zig_opt):
    env = dict(os.environ)
    env.pop("TCC_DISABLE_PASS", None)

    def run(args):
        return subprocess.run(args, check=True, capture_output=True, text=True, env=env).stdout

    c_file = tmp_path / "replay.c"
    obj = tmp_path / "replay.o"
    run([
        "zig", "build-obj", "-target", "thumb-freestanding-eabi", "-mcpu=cortex_m33",
        "-O", zig_opt, "-ofmt=c", f"-femit-bin={c_file}",
        "--global-cache-dir", str(ROOT / ".cache/zig-global"),
        "--dep", "template",
        f"-Mroot={ROOT / 'dynamic_loader/tests/thunk_replay_codegen.zig'}",
        f"-Mtemplate={ROOT / 'dynamic_loader/source/template.zig'}",
    ])
    zig_lib = re.search(r'\.lib_dir = "([^"]+)"', run(["zig", "env"]))[1]
    tcc = str(ROOT / "libs/tinycc/bin/armv8m-tcc")
    run([
        tcc, "-O2", "-fno-pic", "-mno-sb-relative-got", "-ffunction-sections",
        f"-I{zig_lib}", "-c", str(c_file), "-o", str(obj),
    ])
    disassembly = run(["arm-none-eabi-objdump", "-dr", str(obj)])
    body = re.search(r"^[0-9a-f]+ <replay>:\n(.*?)(?=\nDisassembly|\Z)", disassembly, re.M | re.S)
    assert body, disassembly
    assert not re.search(r"\b[us]div\b", body[1]), body[1]
    calls = re.findall(r"R_ARM_THM_(?:CALL|JUMP24)\s+(\S+)", body[1])
    assert not any(name in ("memcpy", "memmove") or "div" in name for name in calls), calls

    # Check the real assembly against the same Zig constant used by replay.
    # Its two literal loads read the descriptor words at +8 and +12, and
    # its trailing data symbol records the actual template length.
    asm_obj = tmp_path / "thunk.o"
    asm_bin = tmp_path / "thunk.bin"
    run([tcc, "-c", str(ROOT / "dynamic_loader/source/arch/armv8-m/indirect_call_thunk.S"), "-o", str(asm_obj)])
    run(["arm-none-eabi-objcopy", "-O", "binary", "-j", ".text", str(asm_obj), str(asm_bin)])
    code = asm_bin.read_bytes()
    assert code[:8] == bytes.fromhex("dff80490dff804f0")
    assert code[8:16] == b"\xff" * 8
    assert len(code) == 20 and struct.unpack_from("<I", code, 16)[0] == 16
    size = re.search(r"^[0-9a-f]+ <slot_size>:\n(.*?)(?=\nDisassembly|\Z)", disassembly, re.M | re.S)
    assert size and re.search(r"\bmovs?\s+r0, #16\b", size[1]), disassembly
