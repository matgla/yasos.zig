"""
GDB helper script to automatically load symbols from yasld UART log output.

Usage in GDB:
    (gdb) source scripts/yasld_gdb.py
    (gdb) yasld-load /path/to/uart.log
    (gdb) yasld-load                     # reads from stdin (paste log, then Ctrl-D)

Standalone usage (prints GDB commands to stdout):
    python3 scripts/yasld_gdb.py /path/to/uart.log
    python3 scripts/yasld_gdb.py < uart.log

You can also pipe directly into GDB:
    python3 scripts/yasld_gdb.py uart.log > /tmp/gdb_cmds.txt
    (gdb) source /tmp/gdb_cmds.txt
"""

import re
import os
import sys

# -- Configuration ----------------------------------------------------------
# Base directory of the project (relative to where GDB is launched from).
# Adjust if you launch GDB from a different directory.
PROJECT_ROOT = "."

# Map from the library/binary name in the yasld log to the ELF file path
# (relative to PROJECT_ROOT). Add new entries as you add new shared libs.
ELF_MAP = {
    "libpthread.so":  "libs/pthread/build/libpthread.so.elf",
    "libdl.so":       "libs/libdl/build/libdl.so.elf",
    "libc.so":        "libs/libc/build/libc.so.elf",
    "libm.so":        "libs/libm/build/libm.so",
    "libncurses.so":  "libs/yasos_curses/build/libncurses.so.elf",
    "libtermcap.so":  "libs/termcap/build/libtermcap.so.elf",
    "armv8m-tcc":     "libs/tinycc/bin/armv8m-tcc.elf",
    # Apps
    "hello":          "apps/hello_world/build/hello.elf",
    "tv":             "apps/ascii_animations/build/tv.elf",
    "textvaders":     "apps/textvaders/build/textvaders.elf",
    "toybox":         "apps/toybox/toybox.elf",
    "zork":           "apps/zork/zork.elf",
    "sha256sum":      "apps/sha/build/sha256sum.elf",
    "rz":             "apps/rzsz/build/rz.elf",
    "jump_test":      "apps/longjump_tester/build/jump_test.elf",
    "mkfs.lfs":       "apps/mkfs/build/mkfs.lfs.elf",
    "mkfs.fat":       "apps/mkfs/build/mkfs.fat.elf",
}

# Sections we care about for add-symbol-file
# .text is the primary (positional arg), the rest are -s flags
PLACEHOLDER_ADDR = "0xaaaaaaaa"

# -- Parsing ----------------------------------------------------------------
# Matches lines like:
# [ERR][yasld] .text loaded at 0x101ce9d0, size: 0 for: libpthread.so
# [ERR][yasld] .got  loaded at 0x11022000, entr: 3 for: libpthread.so
LOG_PATTERN = re.compile(
    r"\[ERR\]\[yasld\]\s+"
    r"(?P<section>\.\w+)\s+"
    r"loaded at\s+(?P<addr>0x[0-9a-fA-F]+),\s+"
    r"(?:size|entr):\s+[0-9a-fA-F]+\s+"
    r"for:\s+(?P<name>\S+)"
)


def parse_log(text):
    """
    Parse yasld log text and return a dict:
        { "libc.so": { ".text": "0x10178270", ".data": "0x11024000", ... }, ... }
    """
    libs = {}
    for line in text.splitlines():
        m = LOG_PATTERN.search(line)
        if not m:
            continue
        section = m.group("section")
        addr = m.group("addr")
        name = m.group("name")

        if name not in libs:
            libs[name] = {}
        libs[name][section] = addr

    return libs


def generate_commands(libs, project_root=PROJECT_ROOT):
    """
    Generate add-symbol-file GDB commands from parsed lib info.
    Returns a list of command strings.
    """
    commands = []
    for name, sections in libs.items():
        # Find the ELF file
        elf_path = ELF_MAP.get(name)
        if elf_path is None:
            commands.append(f"# WARNING: no ELF mapping for '{name}' - add it to ELF_MAP in yasld_gdb.py")
            continue

        full_path = os.path.join(project_root, elf_path)

        # .text address is the positional argument
        text_addr = sections.get(".text")
        if not text_addr or text_addr == PLACEHOLDER_ADDR:
            commands.append(f"# SKIP {name}: .text address is placeholder or missing")
            continue

        # Build the command
        cmd_parts = [f"add-symbol-file {full_path} {text_addr}"]

        # Add other sections (skip .text since it's positional, skip placeholders)
        for sec_name in [".data", ".bss", ".rodata", ".plt", ".got"]:
            addr = sections.get(sec_name)
            if addr and addr != PLACEHOLDER_ADDR:
                cmd_parts.append(f"-s {sec_name} {addr}")

        commands.append(" ".join(cmd_parts))

    return commands


# -- GDB integration --------------------------------------------------------
try:
    import gdb

    class YasldLoadCommand(gdb.Command):
        """Load symbols from yasld UART log output.

        Usage:
            yasld-load /path/to/uart.log
        """

        def __init__(self):
            super().__init__("yasld-load", gdb.COMMAND_USER)
            # Track loaded files so we can remove old symbols before reloading
            self._loaded_files = []

        def invoke(self, arg, from_tty):
            arg = arg.strip()

            if not arg:
                gdb.write("Usage: yasld-load /path/to/uart.log\n")
                gdb.write("  Tip: use picocom --logfile /tmp/uart.log to capture the log\n")
                return

            log_path = arg
            if not os.path.isfile(log_path):
                gdb.write(f"Error: file not found: {log_path}\n")
                return
            with open(log_path, "r") as f:
                text = f.read()

            libs = parse_log(text)
            if not libs:
                gdb.write("No yasld section entries found in the log.\n")
                return

            # Remove previously loaded symbols so we don't get stale/duplicate entries
            if self._loaded_files:
                gdb.write(f"Removing {len(self._loaded_files)} previously loaded symbol files...\n")
                for elf in self._loaded_files:
                    try:
                        gdb.execute(f"remove-symbol-file {elf}", to_string=True)
                    except gdb.error:
                        pass  # may already be gone
                self._loaded_files.clear()

            # Determine project root from GDB's current directory
            project_root = os.getcwd()
            commands = generate_commands(libs, project_root)

            gdb.write(f"\n--- Loading symbols for {len(libs)} libraries ---\n")
            for cmd in commands:
                if cmd.startswith("#"):
                    gdb.write(cmd + "\n")
                else:
                    gdb.write(f"  {cmd}\n")
                    try:
                        gdb.execute(cmd)
                        # Extract the ELF path from the command for later removal
                        elf = cmd.split()[1]
                        self._loaded_files.append(elf)
                    except gdb.error as e:
                        gdb.write(f"  ERROR: {e}\n")
            gdb.write("--- Done ---\n")

    YasldLoadCommand()
    gdb.write("yasld-load command registered. Use 'yasld-load <logfile>' to load symbols.\n")

    _IN_GDB = True

except ImportError:
    # Not running inside GDB - standalone mode
    _IN_GDB = False


# -- Standalone entry point -------------------------------------------------
def main():
    if len(sys.argv) > 1:
        log_path = sys.argv[1]
        with open(log_path, "r") as f:
            text = f.read()
    else:
        text = sys.stdin.read()

    libs = parse_log(text)
    if not libs:
        print("# No yasld section entries found in the log.", file=sys.stderr)
        sys.exit(1)

    commands = generate_commands(libs)
    for cmd in commands:
        print(cmd)


if not _IN_GDB and __name__ == "__main__":
    main()
