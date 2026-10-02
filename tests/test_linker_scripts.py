"""The RP2350 Debug linker script is a copy of the release one, and must stay one.

`hal/build.zig` swaps in `linker_script_debug.ld` for a Zig Debug kernel, whose
frames need a bigger MSP stack than the release layout gives it. It is a whole
second script rather than an INCLUDE (see `debug_variant` there for why), so the
only thing keeping a section, a symbol or an ASSERT added to the release script
from silently missing in the Debug one is this test.
"""

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = REPO_ROOT / "hal" / "source" / "raspberry" / "rp2350"
RELEASE = SCRIPTS / "linker_script.ld"
DEBUG = SCRIPTS / "linker_script_debug.ld"

#: The regions the Debug layout moves, and nothing else is allowed to differ.
MOVED = ("process_ram", "core1_stack", "scratch")

REGION = re.compile(r"^\s*(\w+)\s*\([^)]*\)\s*:\s*ORIGIN\s*=\s*(0x[0-9A-Fa-f]+)\s*,\s*LENGTH\s*=\s*(\d+)K", re.M)


def _body(path: Path) -> list[str]:
    """The script from its MEMORY block on, with the moved regions' lines blanked."""
    text = path.read_text()
    text = text[text.index("MEMORY"):]
    return [
        "<moved region>" if any(line.strip().startswith(name + "(") for name in MOVED) else line
        for line in text.splitlines()
    ]


def _regions(path: Path) -> dict[str, tuple[int, int]]:
    return {name: (int(origin, 16), int(length) * 1024) for name, origin, length in REGION.findall(path.read_text())}


def test_debug_script_differs_only_in_the_moved_regions():
    assert _body(DEBUG) == _body(RELEASE)


def test_debug_layout_still_tiles_the_top_of_sram():
    """Process RAM, core 1's stack and core 0's stack butt up against each other
    and end exactly at the top of SRAM, as they do in the release layout -- the
    ASSERT in the script checks the one seam, this checks all three."""
    for path in (RELEASE, DEBUG):
        regions = _regions(path)
        process_origin, process_length = regions["process_ram"]
        core1_origin, core1_length = regions["core1_stack"]
        scratch_origin, scratch_length = regions["scratch"]
        assert process_origin + process_length == core1_origin, path.name
        assert core1_origin + core1_length == scratch_origin, path.name
        assert scratch_origin + scratch_length == 0x20082000, path.name


def test_debug_kernel_gets_the_bigger_stack():
    assert _regions(DEBUG)["scratch"][1] == 32 * 1024
    assert _regions(RELEASE)["scratch"][1] == 16 * 1024
