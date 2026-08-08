# Measure user SP across each signal() call in mkdir's toy_exec_which signal
# loop, using ONLY toybox (user-code) breakpoints, which halt reliably on the
# RP2350 (kernel-code breakpoints trip E0E/disconnects).
#
#   e60a (0x103e8cea)  bl signal@plt   [before the call+its syscall]
#   e60e (0x103e8cee)  ldr.w r9,[sp]   [after signal() returns]
# SP at e60a and the following e60e must be identical; a positive delta means
# the signal() syscall drifted the user SP.
import gdb

CALL = 0x103E8CEA
RET = 0x103E8CEE
state = {"pre": None, "hits": 0}


def _reg(name):
    return int(gdb.selected_frame().read_register(name)) & 0xFFFFFFFF


class CallBP(gdb.Breakpoint):
    def __init__(self):
        super().__init__("*0x%x" % CALL, type=gdb.BP_HARDWARE_BREAKPOINT)
        self.silent = True

    def stop(self):
        sp = _reg("sp")
        if sp < 0x11000000 or sp >= 0x11800000:
            return False
        state["pre"] = sp
        gdb.write("[call] sp=0x%08x r9=0x%08x\n" % (sp, _reg("r9")))
        return False


class RetBP(gdb.Breakpoint):
    def __init__(self):
        super().__init__("*0x%x" % RET, type=gdb.BP_HARDWARE_BREAKPOINT)
        self.silent = True

    def stop(self):
        sp = _reg("sp")
        if sp < 0x11000000 or sp >= 0x11800000:
            return False
        pre = state["pre"]
        delta = (sp - pre) if pre is not None else 0
        gdb.write("[ret ] sp=0x%08x r9=0x%08x  delta_vs_call=%+d\n"
                  % (sp, _reg("r9"), delta))
        state["hits"] += 1
        if state["hits"] >= 8:
            gdb.write("[done]\n")
            return True
        return False


CallBP()
RetBP()
gdb.write("armed signal-loop SP-drift probe\n")
gdb.execute("continue")
