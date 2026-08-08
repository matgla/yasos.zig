# Breakpoint probe for the `#if X >= Y` pp-expression miscompile.
# The board is reset-halted; a background serial sender will re-issue the tcc
# command once we `continue` (which boots the target). We break where the
# parser gives up ("expression expected before '<eof>'") — the FIRST such hit
# is the failing predefined #if — and dump the parse state so we can see how the
# token stream pointer (macro_ptr) over-advanced past the 2nd operand.
set pagination off
set confirm off
set width 0

# unary() emits this when it can't start an expression (tccgen.c ~22800).
break tccgen.c:22800

python
import gdb
print("\n=== bp_probe: continuing; waiting for the parser error breakpoint ===")
try:
    gdb.execute("continue")
except gdb.error as e:
    print("continue error: %s" % e)

print("\n=============== PARSER-ERROR STATE ===============")
def t(cmd):
    try:
        gdb.execute(cmd)
    except gdb.error as e:
        print("  (%s: %s)" % (cmd, e))

t("bt")
print("\n--- token / stream pointers ---")
for v in ("tok", "tokc", "macro_ptr", "macro_stack", "file"):
    t("print %s" % v)
print("\n--- 16 words at macro_ptr (where the next token would be read) ---")
t("x/16xw macro_ptr")
print("\n--- the macro token-string buffer (start of the #if expansion) ---")
t("print macro_stack")
t("x/24xw macro_stack")
print("\n--- caller frames source ---")
t("frame 1")
t("info locals")
t("frame 2")
t("info locals")
print("=============== END STATE ===============\n")
end
quit
