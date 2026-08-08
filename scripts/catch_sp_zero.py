# Catch the instruction that zeroes the caller's [sp] word across a @plt
# syscall (the bug that leaves r9=0 after `ldr r9,[sp]`). Debug-build toybox.
#
# toy_singleinit (toybox .text base 0x103dd9e0):
#   eda0  str   r0,[sp]          value lives in [sp]
#   eda4  bl    nl_langinfo@plt  <- the syscall suspected to zero [sp]
#   eda8  ldr   r9,[sp]          restore GOT base  <- reads 0 on device
#   edb4  add   r0,r9            GOT-relative -> wild ptr when r9=0
#
# At eda4 arm a hardware WRITE watchpoint on the [sp] word. Any write of a value
# different from what was there at the call is the corruptor -> stop and report
# the PC (expected: a kernel SVC / context-switch instruction). Also report SP
# at the call vs at the restore to reveal pure SP drift.
import gdb

BASE = 0x103DD9E0
ADDR_CALL = BASE + 0x0EDA4   # bl nl_langinfo@plt
ADDR_AFTER = BASE + 0x0EDA8  # ldr r9,[sp]
ADDR_RET = BASE + 0x0EDBE    # cmp r0,#0 (well past the restore)

state = {"wp": None, "sp_call": None}


def _r(name):
    return int(gdb.selected_frame().read_register(name)) & 0xFFFFFFFF


def _word(a):
    return int(gdb.parse_and_eval("*(unsigned int *)0x%x" % a)) & 0xFFFFFFFF


class CorruptWatch(gdb.Breakpoint):
    def __init__(self, addr, expect):
        super().__init__("*(unsigned int *)0x%x" % addr,
                         type=gdb.BP_WATCHPOINT, wp_class=gdb.WP_WRITE, internal=False)
        self.addr = addr
        self.expect = expect
        self.silent = True

    def stop(self):
        try:
            val = _word(self.addr); pc = _r("pc")
        except gdb.error:
            return False
        if val == self.expect:
            return False
        gdb.write("\n*** [sp]=0x%08x WRITTEN 0x%08x (was 0x%08x) at pc=0x%08x ***\n"
                  % (self.addr, val, self.expect, pc))
        try:
            gdb.execute("info registers r0 r1 r2 r3 r9 sp lr pc")
            gdb.write("--- disasm around corruptor ---\n")
            gdb.execute("x/14i 0x%x" % (pc - 0x14))
        except gdb.error:
            pass
        return True


class CallBP(gdb.Breakpoint):
    def __init__(self):
        super().__init__("*0x%x" % ADDR_CALL, type=gdb.BP_HARDWARE_BREAKPOINT, internal=False)
        self.silent = True

    def stop(self):
        sp = _r("sp")
        if sp < 0x11000000 or sp >= 0x11800000:
            return False  # only the PSRAM-stack (failing) process
        slot = _word(sp)
        state["sp_call"] = sp
        gdb.write("[call] nl_langinfo sp=0x%08x r9=0x%08x [sp]=0x%08x\n" % (sp, _r("r9"), slot))
        if state["wp"] is not None:
            try: state["wp"].delete()
            except gdb.error: pass
        state["wp"] = CorruptWatch(sp, slot)
        gdb.write("[arm] watch [sp]=0x%08x (expect stays 0x%08x)\n" % (sp, slot))
        return False


class AfterBP(gdb.Breakpoint):
    def __init__(self):
        super().__init__("*0x%x" % ADDR_RET, type=gdb.BP_HARDWARE_BREAKPOINT, internal=False)
        self.silent = True

    def stop(self):
        sp = _r("sp"); r9 = _r("r9")
        slot = _word(sp) if 0x11000000 <= sp < 0x11800000 else 0xDEAD
        drift = (sp - state["sp_call"]) if state["sp_call"] else 0
        gdb.write("[after] sp=0x%08x r9=0x%08x [sp]=0x%08x drift=%+d\n" % (sp, r9, slot, drift))
        if state["wp"] is not None:
            try: state["wp"].delete()
            except gdb.error: pass
            state["wp"] = None
        return False


CallBP()
AfterBP()
gdb.write("armed [sp]-zero catcher at toy_singleinit nl_langinfo@plt\n")
gdb.execute("continue")
