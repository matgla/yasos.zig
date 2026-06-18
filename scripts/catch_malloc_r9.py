# Catch the instruction that corrupts xmalloc's saved-r9 stack slot during the
# first `bl malloc@plt` (the lazy PLT resolve SVC). Debug-build toybox.
#
# xmalloc (toybox .text base 0x103dd9e0):
#   bff2  str.w r9,[sp]     save GOT base at [sp]  (legit writer)
#   bff6  bl malloc@plt     FIRST malloc -> lazy resolver thunk -> SVC
#   bffc  ldr.w r9,[sp]     restore GOT base  <-- reads CORRUPTED value on device
#   c01c  pop {r4,r5,pc}    return
#
# Strategy: at bff6 (str already ran, [sp]=GOT) arm a hardware WRITE watchpoint
# on that [sp] word. Anything that writes a value other than the saved GOT base
# is the corruptor -> stop and report its PC (expected: a kernel SVC-path
# instruction). Also log SP at call vs at the restore to catch pure SP drift.
import gdb

BASE = 0x103DD9E0
ADDR_CALL = BASE + 0x0BFF6   # bl malloc@plt
ADDR_AFTER = BASE + 0x0C000  # cmp r5,#0 (after ldr r9,[sp])
ADDR_RET = BASE + 0x0C01C    # pop {r4,r5,pc}

state = {"wp": None, "addr": None, "expect": None, "sp_call": None, "armed_once": False}


def _r(name):
    return int(gdb.selected_frame().read_register(name)) & 0xFFFFFFFF


def _word(addr):
    return int(gdb.parse_and_eval("*(unsigned int *)0x%x" % addr)) & 0xFFFFFFFF


class CorruptWatch(gdb.Breakpoint):
    def __init__(self, addr, expect):
        super().__init__("*(unsigned int *)0x%x" % addr,
                         type=gdb.BP_WATCHPOINT, wp_class=gdb.WP_WRITE, internal=False)
        self.addr = addr
        self.expect = expect
        self.silent = True

    def stop(self):
        try:
            val = _word(self.addr)
            pc = _r("pc")
        except gdb.error:
            return False
        if val == self.expect:
            return False  # legit re-store of the same GOT base; keep going
        gdb.write("\n*** [sp]=0x%08x WRITTEN 0x%08x (expected 0x%08x) at pc=0x%08x ***\n"
                  % (self.addr, val, self.expect, pc))
        try:
            gdb.execute("info registers r0 r1 r2 r3 r4 r9 sp lr pc")
            gdb.write("--- disasm around corruptor PC ---\n")
            gdb.execute("x/12i 0x%x" % (pc - 0x10))
            gdb.write("--- watched slot neighborhood ---\n")
            gdb.execute("x/12x 0x%x" % (self.addr - 16))
        except gdb.error:
            pass
        return True


class CallBP(gdb.Breakpoint):
    def __init__(self):
        super().__init__("*0x%x" % ADDR_CALL, type=gdb.BP_HARDWARE_BREAKPOINT, internal=False)
        self.silent = True

    def stop(self):
        sp = _r("sp")
        r9 = _r("r9")
        if sp < 0x11000000 or sp >= 0x11800000:
            return False
        slot = _word(sp)
        state["sp_call"] = sp
        gdb.write("[call] malloc@plt sp=0x%08x r9=0x%08x [sp]=0x%08x\n" % (sp, r9, slot))
        if state["wp"] is not None:
            try: state["wp"].delete()
            except gdb.error: pass
        state["wp"] = CorruptWatch(sp, slot)
        state["addr"] = sp
        state["expect"] = slot
        gdb.write("[arm] watch write to [sp]=0x%08x (expect stays 0x%08x)\n" % (sp, slot))
        return False


class AfterBP(gdb.Breakpoint):
    def __init__(self):
        super().__init__("*0x%x" % ADDR_AFTER, type=gdb.BP_HARDWARE_BREAKPOINT, internal=False)
        self.silent = True

    def stop(self):
        sp = _r("sp")
        r9 = _r("r9")
        slot = _word(sp) if 0x11000000 <= sp < 0x11800000 else 0xDEAD
        drift = (sp - state["sp_call"]) if state["sp_call"] is not None else 0
        gdb.write("[after] sp=0x%08x r9=0x%08x [sp]=0x%08x  sp_drift_vs_call=%+d\n"
                  % (sp, r9, slot, drift))
        return False


class RetBP(gdb.Breakpoint):
    def __init__(self):
        super().__init__("*0x%x" % ADDR_RET, type=gdb.BP_HARDWARE_BREAKPOINT, internal=False)
        self.silent = True

    def stop(self):
        if state["wp"] is not None:
            try: state["wp"].delete()
            except gdb.error: pass
            state["wp"] = None
        return False


CallBP()
AfterBP()
RetBP()
gdb.write("armed xmalloc saved-r9 corruptor catcher (bff6 arm / c01c disarm)\n")
gdb.execute("continue")
