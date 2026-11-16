"""strip against images the cross compiler links with -g.

Runs the host build (`make host`); the board build is the same source.  What
is checked is the contract in tccyaff.h: the image the loader reads survives
byte for byte, the debug data moves to the -f file unchanged but for its image
CRC, and the link left behind names that file with the same CRC.
"""

import importlib.util
import shutil
import struct
import subprocess
import zlib
from pathlib import Path

import pytest

HERE = Path(__file__).parent
STRIP_DIR = HERE.parent
REPO = STRIP_DIR.parent.parent
TINYCC = REPO / "libs" / "tinycc"
TCC = TINYCC / "armv8m-tcc"
STRIP = STRIP_DIR / "build-host" / "strip"
BUILD = HERE / "build"

DEBUG_FIELDS = 136  # YaffHeader.debug_offset, then debug_length
HEADER_SIZE = 144

SOURCE = """\
static int counter;
int table[4] = {1, 2, 3, 4};
static int add(int a, int b) { return a + b + counter; }
int f(int x)
{
  counter = x;
  return add(x, table[x & 3]);
}
"""


@pytest.fixture(scope="session", autouse=True)
def tools():
    if not TCC.exists():
        pytest.skip(f"no cross compiler at {TCC}")
    subprocess.run(["make", "-C", str(STRIP_DIR), "host"], check=True, stdout=subprocess.DEVNULL)


def link(tmp_path, name, debug):
    src = tmp_path / "module.c"
    src.write_text(SOURCE)
    out = tmp_path / name
    flags = ["-g"] if debug else []
    subprocess.run(
        [str(TCC), *flags, "-nostdlib", "-nodefaultlibs", "-shared", "-Wl,-oformat=yaff", str(src), "-o", str(out)],
        check=True,
    )
    return out


def strip(*args, check=True):
    return subprocess.run([str(STRIP), *map(str, args)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          check=check)


def debug_fields(data):
    return struct.unpack_from("<II", data, DEBUG_FIELDS)


def image_crc(data, debug_offset):
    image = bytearray(data[:debug_offset])
    image[DEBUG_FIELDS:HEADER_SIZE] = bytes(8)
    return zlib.crc32(bytes(image))


def blob_header(blob):
    magic, version, count, size, sections, names, names_size, crc = struct.unpack_from("<4sHHIIIII", blob)
    return {"magic": magic, "version": version, "count": count, "size": size, "sections": sections,
            "names": names, "names_size": names_size, "crc": crc}


def blob_sections(blob):
    h = blob_header(blob)
    names = blob[h["names"]: h["names"] + h["names_size"]]
    out = {}
    for i in range(1, h["count"]):
        f = struct.unpack_from("<10I", blob, h["sections"] + i * 40)
        name = names[f[0]: names.index(b"\0", f[0])].decode()
        out[name] = {"type": f[1], "offset": f[4], "size": f[5]}
    return out


def test_strip_in_place_drops_the_debug_data(tmp_path):
    # One basename: the image records it.
    (tmp_path / "plain").mkdir()
    plain = link(tmp_path / "plain", "module.yaff", False)
    image = link(tmp_path, "module.yaff", True)
    before = image.read_bytes()
    debug_offset, _ = debug_fields(before)
    assert debug_offset

    strip(image)
    after = image.read_bytes()
    assert debug_fields(after) == (0, 0)
    assert after[HEADER_SIZE:] == before[HEADER_SIZE:debug_offset]
    assert after[:DEBUG_FIELDS] == before[:DEBUG_FIELDS]
    # The same image a link without -g writes, up to the alignment padding.
    assert after[: len(plain.read_bytes())] == plain.read_bytes()
    assert image.stat().st_mode & 0o111  # still executable


def test_strip_f_splits_the_debug_data_off_and_links_it(tmp_path):
    image = link(tmp_path, "module.yaff", True)
    before = image.read_bytes()
    debug_offset, debug_length = debug_fields(before)
    crc = image_crc(before, debug_offset)
    debug_file = tmp_path / "debug" / "module.yaff.debug"
    debug_file.parent.mkdir()

    strip("-f", debug_file, image)

    # The debug file: the blob as the link wrote it, with the image's CRC.
    saved = debug_file.read_bytes()
    original = before[debug_offset:]
    assert len(saved) == debug_length
    assert blob_header(saved)["crc"] == crc
    assert saved[:24] == original[:24] and saved[28:] == original[28:]
    assert blob_header(original)["crc"] == 0

    # The image: same bytes up to debug_offset, then a blob naming the file.
    after = image.read_bytes()
    offset, length = debug_fields(after)
    assert offset == debug_offset
    assert offset + length == len(after)
    assert image_crc(after, offset) == crc
    link_blob = after[offset:]
    h = blob_header(link_blob)
    assert (h["magic"], h["version"], h["size"], h["crc"]) == (b"YDBG", 1, length, crc)
    sections = blob_sections(link_blob)
    assert list(sections) == [".yaff_debuglink"]
    s = sections[".yaff_debuglink"]
    assert s["type"] == 0x80000001
    assert link_blob[s["offset"]: s["offset"] + s["size"]] == b"module.yaff.debug\0"

    # Splitting again has nothing to split; a plain strip keeps the link.
    assert strip("-f", tmp_path / "again.debug", image, check=False).returncode != 0
    strip(image)
    assert image.read_bytes() == after


def test_debug_file_converts_to_elf(tmp_path):
    image = link(tmp_path, "module.yaff", True)
    debug_file = tmp_path / "module.debug"
    strip("-f", debug_file, image)
    spec = importlib.util.spec_from_file_location("yaff_debug_to_elf", TINYCC / "scripts" / "yaff_debug_to_elf.py")
    tool = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tool)
    elf = tmp_path / "module.elf"
    elf.write_bytes(tool.to_elf(tool.find_blob(debug_file.read_bytes())))
    if shutil.which("arm-none-eabi-readelf"):
        lines = subprocess.run(["arm-none-eabi-readelf", "--debug-dump=decodedline", str(elf)],
                               stdout=subprocess.PIPE, text=True, check=True).stdout
        assert "module.c" in lines


def test_strip_o_leaves_the_input_alone(tmp_path):
    image = link(tmp_path, "module.yaff", True)
    before = image.read_bytes()
    out = tmp_path / "stripped.yaff"
    strip("-o", out, image)
    assert image.read_bytes() == before
    assert debug_fields(out.read_bytes()) == (0, 0)


def test_image_without_debug_data(tmp_path):
    image = link(tmp_path, "module.yaff", False)
    before = image.read_bytes()
    strip(image)
    assert image.read_bytes() == before
    out = tmp_path / "copy.yaff"
    strip("-o", out, image)
    assert out.read_bytes() == before
    result = strip("-f", tmp_path / "x.debug", image, check=False)
    assert result.returncode != 0 and "no debug data" in result.stderr


def test_rejects_what_is_not_a_yaff_image(tmp_path):
    junk = tmp_path / "junk"
    junk.write_bytes(b"\x7fELF" + bytes(200))
    result = strip(junk, check=False)
    assert result.returncode != 0 and "not a YAFF image" in result.stderr
    assert junk.read_bytes() == b"\x7fELF" + bytes(200)
