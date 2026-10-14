"""Pin the kernel libc's large-clear loop with the YasOS cross compiler."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]


def test_memset_128_byte_loop(tmp_path):
    compiler = ROOT / "libs/tinycc/armv8m-tcc"
    objdump = shutil.which("arm-none-eabi-objdump")
    if not compiler.exists() or not objdump:
        pytest.skip("requires the built ARM cross compiler and objdump")
    obj = tmp_path / "string.o"
    subprocess.run([
        str(compiler), "-O2", "-mcpu=cortex-m33", "-mthumb", "-fno-pic",
        "-mno-sb-relative-got", "-fno-module-local-calls", "-ffunction-sections",
        "-c", str(ROOT / "libs/libc/string.c"), "-o", str(obj),
    ], check=True, capture_output=True, text=True)
    disasm = subprocess.check_output([
        objdump, "-d", "--no-show-raw-insn", "--disassemble=memset", str(obj),
    ], text=True)
    insns = {}
    for line in disasm.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+(\S+)\s*(.*)", line)
        if m:
            insns[int(m[1], 16)] = (m[2], m[3])
    loops = []
    for pc, (mnemonic, operands) in insns.items():
        target = re.match(r"([0-9a-f]+)\s+<memset", operands)
        if mnemonic.startswith("bcs") and target and int(target[1], 16) < pc:
            loops.append([op for addr, op in insns.items() if int(target[1], 16) <= addr <= pc])
    wide = [loop for loop in loops if sum(m == "strd" for m, _ in loop) == 16]
    assert len(wide) == 1, disasm
    assert len(wide[0]) == 19, wide[0]
    assert wide[0][-3][0].startswith("add") and "#128" in wide[0][-3][1]
    assert wide[0][-2][0].startswith("subs") and "#128" in wide[0][-2][1]
