# Catch the instruction that zeroes toybox's saved-r9 stack slot ([sp]) during
# the toy_exec_which signal-reset loop, which makes the next `bl signal@plt`
# run with r9=0 and jump to 0.
#
# toybox is XIP from romfs at a fixed base; .text runtime base = 0x103da6e0.
#   e602  str.w r9,[sp]    (save GOT, legit writer)
#   e60a  bl signal@plt    (the call whose syscall is suspected to corrupt [sp])
#   e60e  ldr.w r9,[sp]    (restore GOT)
#   e696  pop {r4,r5,r6,pc} (toy_exec_which return)
#
# Strategy: at e60a (after the legit str has run) arm a hardware WRITE watchpoint
# on the current process's [sp] word. When something writes 0 to it, stop and
# report the writing PC (this is the corruptor — likely a kernel syscall path).
# The watchpoint is dropped at function return so a clean loop costs nothing.

import gdb

BASE = 0x103DA6E0
ADDR_CALL = BASE + 0x0E60A   # bl signal@plt
ADDR_RET = BASE + 0x0E696    # toy_exec_which return

state = {"wp": None, "addr": None}


def _reg(name):
    return int(gdb.selected_frame().read_register(name)) & 0xFFFFFFFF


class ZeroWatch(gdb.Breakpoint):
    def __init__(self, addr):
        super().__init__(
            "*(unsigned int *)0x%x" % addr,
            type=gdb.BP_WATCHPOINT,
            wp_class=gdb.WP_WRITE,
            internal=False,
        )
        self.addr = addr
        self.silent = True

    def stop(self):
        try:
            val = int(gdb.parse_and_eval("*(unsigned int *)0x%x" % self.addr)) & 0xFFFFFFFF
            pc = _reg("pc")
        except gdb.error:
            return False
        if val != 0:
            return False  # legit write of a valid GOT pointer; keep going
        gdb.write("\n*** [sp]=0x%08x WRITTEN 0 at pc=0x%08x ***\n" % (self.addr, pc))
        try:
            gdb.execute("info registers r0 r1 r2 r3 r4 r5 r9 sp lr pc")
            gdb.write("--- disasm around firing PC ---\n")
            gdb.execute("x/16i 0x%x" % (pc - 0x18))
            gdb.write("--- raw words around firing PC ---\n")
            gdb.execute("x/24x 0x%x" % (pc - 0x20))
            gdb.write("--- stack around zeroed slot ---\n")
            gdb.execute("x/16x 0x%x" % (self.addr - 16))
        except gdb.error:
            pass
        return True


class SaveBP(gdb.Breakpoint):
    def __init__(self):
        super().__init__("*0x%x" % ADDR_CALL, type=gdb.BP_HARDWARE_BREAKPOINT, internal=False)
        self.silent = True

    def stop(self):
        try:
            r9 = _reg("r9")
            sp = _reg("sp")
        except gdb.error:
            return False
        # Only meaningful while r9 is a valid GOT pointer (kernel SRAM 0x2000_0000..0x2008_2000).
        if r9 < 0x20000000 or r9 >= 0x20082000:
            gdb.write("[note] e60a hit with r9=0x%08x (not a GOT ptr) sp=0x%08x\n" % (r9, sp))
            return False
        if state["addr"] != sp:
            if state["wp"] is not None:
                try:
                    state["wp"].delete()
                except gdb.error:
                    pass
            state["wp"] = ZeroWatch(sp)
            state["addr"] = sp
            gdb.write("[arm] watch [sp]=0x%08x  r9=0x%08x\n" % (sp, r9))
        return False


class RetBP(gdb.Breakpoint):
    def __init__(self):
        super().__init__("*0x%x" % ADDR_RET, type=gdb.BP_HARDWARE_BREAKPOINT, internal=False)
        self.silent = True

    def stop(self):
        # Loop finished without a zero-write for this process; drop the watchpoint.
        if state["wp"] is not None:
            try:
                state["wp"].delete()
            except gdb.error:
                pass
            state["wp"] = None
            state["addr"] = None
        return False


SaveBP()
RetBP()
gdb.write("armed toybox r9-zero catcher (e60a arm / e696 disarm)\n")
gdb.execute("continue")
