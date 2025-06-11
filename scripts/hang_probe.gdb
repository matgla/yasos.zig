# Live-state hang probe: target was HALTED in place (no reset), so we are
# stopped wherever the hung program currently is. Symbolize PC/LR, dump the
# backtrace and the instructions around PC for each core.
python
import gdb

print("\n=============== HANG PROBE ===============")

def try_exec(cmd):
    try:
        gdb.execute(cmd)
    except gdb.error as e:
        print("  (%s: %s)" % (cmd, e))

# Enumerate threads/cores; rp2350 has 2 cores. Inspect each.
try:
    inf = gdb.selected_inferior()
    threads = inf.threads()
except Exception as e:
    threads = []
    print("  (no threads: %s)" % e)

for th in threads:
    try:
        th.switch()
        name = th.name or "?"
        print("\n--- thread %s (%s) ---" % (th.num, name))
    except Exception as e:
        print("\n--- thread switch failed: %s ---" % e)
        continue
    try_exec("info registers pc sp lr")
    # symbol for pc
    try:
        pc = int(gdb.parse_and_eval("$pc")) & ~1
        print("  PC = 0x%08x" % pc)
        try_exec("info symbol 0x%x" % pc)
        lr = int(gdb.parse_and_eval("$lr")) & ~1
        print("  LR = 0x%08x" % lr)
        try_exec("info symbol 0x%x" % lr)
    except Exception as e:
        print("  (pc/lr eval: %s)" % e)
    try_exec("backtrace")
    print("  --- insns around PC ---")
    try:
        pc = int(gdb.parse_and_eval("$pc")) & ~1
        try_exec("x/24i 0x%x" % (pc - 24))
    except Exception as e:
        print("  (%s)" % e)

print("=============== END HANG PROBE ===============\n")
end
quit
