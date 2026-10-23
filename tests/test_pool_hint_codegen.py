"""Keep the actual Zig hint scanner's TCC loop free of metadata round-trips."""

from pathlib import Path
import os
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]


def _declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def test_pool_hint_scan_keeps_metadata_outside_loop(tmp_path):
    zig = shutil.which("zig")
    objdump = shutil.which("arm-none-eabi-objdump")
    compiler = ROOT / "libs/tinycc/bin/armv8m-tcc"
    if not zig or not objdump or not compiler.exists():
        pytest.skip("requires Zig, the YasOS cross compiler, and objdump")
    source = (ROOT / "source/kernel/memory/heap/process_memory_pool.zig").read_text()
    region = _declaration(source, "const Region = struct")
    scanner = _declaration(source, "inline fn advance_free_hint")
    zig_source = tmp_path / "scan.zig"
    zig_source.write_text(
        'const std = @import("std");\n'
        'const MaskInt = std.bit_set.Dynamic.MaskInt;\n'
        'const bits_per_word = @bitSizeOf(MaskInt);\n'
        + region + ";\n" + scanner + '\n'
        'export fn scan(region: *Region) usize { return advance_free_hint(region); }\n'
    )
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(tmp_path / "global-cache"))
    generated = tmp_path / "scan.c"
    subprocess.run([
        zig, "build-obj", str(zig_source), "-target", "thumb-freestanding-eabi",
        "-mcpu=cortex_m33", "-O", "ReleaseFast", "-ofmt=c", "-fno-llvm",
        "--cache-dir", str(tmp_path / "local-cache"), f"-femit-bin={generated}",
    ], env=env, check=True, capture_output=True, text=True)
    zig_env = subprocess.check_output([zig, "env"], env=env, text=True)
    lib_dir = re.search(r'\.lib_dir = "([^"]+)"', zig_env)[1]
    obj = tmp_path / "scan.o"
    subprocess.run([
        str(compiler), "-O2", "-fno-pic", "-mno-sb-relative-got",
        "-fno-module-local-calls", "-I", lib_dir,
        "-c", str(generated), "-o", str(obj),
    ], check=True, capture_output=True, text=True)
    disasm = subprocess.check_output([
        objdump, "-d", "--no-show-raw-insn", "--disassemble=scan", str(obj),
    ], text=True)
    insns = {}
    for line in disasm.splitlines():
        match = re.match(r"\s*([0-9a-f]+):\s+(\S+)\s*(.*)", line)
        if match:
            insns[int(match[1], 16)] = (match[2], match[3])
    loops = []
    for pc, (mnemonic, operands) in insns.items():
        target = re.match(r"([0-9a-f]+)\s+<scan", operands)
        if mnemonic.startswith("b") and target and int(target[1], 16) < pc:
            loops.append([op for addr, op in insns.items() if int(target[1], 16) <= addr <= pc])
    assert len(loops) == 1, disasm
    memory = [(m, a) for m, a in loops[0] if m.startswith(("ldr", "str"))]
    assert len(memory) == 1 and memory[0][0].startswith("ldr"), disasm
    assert "lsl #2" in memory[0][1], disasm
    assert not any(m in ("bl", "blx") for m, _ in insns.values()), disasm
