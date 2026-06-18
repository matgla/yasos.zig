# Build-independent catcher for the "branch to 0" fault. Arms a hardware
# breakpoint at address 0 (and at the low boot-ROM entry the corrupted pointer
# routes through). When the CPU branches there, halt and dump full state +
# stack so the call chain that produced the bad pointer can be reconstructed.
#
# Use via the live gdb flow (attach to reset-halted target, arm, continue, then
# serial types the command). Works on any build (no hardcoded user addresses).
import gdb

state = {"hits": 0}


def _r(name):
    try:
        return int(gdb.selected_frame().read_register(name)) & 0xFFFFFFFF
    except gdb.error:
        return -1


def _dump(tag):
    gdb.write("\n*** %s ***\n" % tag)
    try:
        gdb.execute("info registers r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc")
    except gdb.error:
        pass
    sp = _r("sp")
    if 0x11000000 <= sp < 0x11800000 or 0x20000000 <= sp < 0x20082000:
        gdb.write("--- stack @sp (48 words) ---\n")
        try:
            gdb.execute("x/48x 0x%x" % sp)
        except gdb.error:
            pass
    # ROM window around lr (where the corrupted pointer routed us)
    lr = _r("lr")
    if 0 <= lr < 0x8000:
        gdb.write("--- ROM around lr ---\n")
        try:
            gdb.execute("x/16i 0x%x" % (lr & ~1))
        except gdb.error:
            pass


class Catch(gdb.Breakpoint):
    def __init__(self, addr):
        super().__init__("*0x%x" % addr, type=gdb.BP_HARDWARE_BREAKPOINT, internal=False)
        self.addr = addr
        self.silent = True

    def stop(self):
        _dump("PC reached 0x%x  (lr=0x%08x r9=0x%08x)" % (self.addr, _r("lr"), _r("r9")))
        state["hits"] += 1
        return True  # halt so the session is interactive for follow-up


Catch(0x0)
gdb.write("armed branch-to-0 catcher (hbreak *0)\n")
gdb.execute("continue")
