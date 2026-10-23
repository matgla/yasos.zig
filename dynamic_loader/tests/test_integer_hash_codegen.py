"""Guard the integer map fast path through Zig's C backend and the kernel tcc."""

import os
from pathlib import Path
import re
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("zig_opt", ["ReleaseFast", "ReleaseSafe"])
def test_integer_hash_avoids_general_hash_and_state_copies(tmp_path, zig_opt):
    c_file = tmp_path / "hash.c"
    obj = tmp_path / "hash.o"
    env = dict(os.environ)
    env.pop("TCC_DISABLE_PASS", None)

    def run(args):
        return subprocess.run(args, check=True, capture_output=True, text=True, env=env).stdout

    run([
        "zig", "build-obj", "-target", "thumb-freestanding-eabi", "-mcpu=cortex_m33",
        "-O", zig_opt, "-ofmt=c", f"-femit-bin={c_file}",
        "--global-cache-dir", str(ROOT / ".cache/zig-global"),
        "--dep", "integer_hash_map",
        f"-Mroot={ROOT / 'dynamic_loader/tests/integer_hash_codegen.zig'}",
        f"-Minteger_hash_map={ROOT / 'dynamic_loader/source/integer_hash_map.zig'}",
    ])
    zig_lib = re.search(r'\.lib_dir = "([^"]+)"', run(["zig", "env"]))[1]
    run([
        str(ROOT / "libs/tinycc/bin/armv8m-tcc"), "-O2", "-fno-pic", "-mno-sb-relative-got",
        "-ffunction-sections", f"-I{zig_lib}", "-c", str(c_file), "-o", str(obj),
    ])
    disassembly = run(["arm-none-eabi-objdump", "-dr", str(obj)])
    for name in ("hash_fd", "hash_pid", "hash_address", "hash_wide"):
        body = re.search(rf"^[0-9a-f]+ <{name}>:\n(.*?)(?=\nDisassembly|\Z)", disassembly, re.M | re.S)
        assert body, disassembly
        calls = re.findall(r"R_ARM_THM_(?:CALL|JUMP24)\s+(\S+)", body[1])
        assert not calls, f"{name} still materializes hash state or calls a helper: {calls}"
