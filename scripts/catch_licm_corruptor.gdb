# Catch the store that smashes tcc_ir_opt_licm_ex's loop-counter stack slot.
#
# Symptom (02/04/05/06/07/08 self-host): tcc_ir_opt_licm_ex reads its block
# loop index `bi` back as garbage (0x2C2B2A29 for 02_printf) and faults on
# is_invariant[bi].  The index lives in stack slot [sp,#72]; it is initialised
# to 0 just before the loop, so a foreign store smashes it DURING the loop.
# This watches that exact slot and halts AT THE CORRUPTOR's own PC.
#
# Deterministic device addresses for the CURRENTLY-FLASHED armv8m-tcc
# (rebuilt 2026-06-09 09:57; .text ELF vaddr0 -> device 0x101E9024):
#   ELF -> device : dev = elf + 0x101E9024     (so elf = dev - 0x101E9024)
#   licm loop-init `b.w` (after `str #0,[sp,#72]`) : ELF 0x13F65E -> dev 0x10328682
#   faulting `ldrb r1,[r0]`                          : ELF 0x13F670 -> dev 0x10328694
#   crashing-frame SP (PSP 0x11065410 + FP frame 0x68) : 0x11065478
#   smashed slot [sp,#72]                              : 0x110654C0
#
# Run via:  remote_smoke_tui.py --gdb-debug --gdb-live \
#             --cmd 'tcc /root/ci/sources/tests2/02_printf.c -o /tmp/02_printf' \
#             --gdb-script scripts/catch_licm_corruptor.gdb
# Uses absolute addresses, so no yasld symbol load is needed up front.

set pagination off
set confirm off
set height 0
set width 0

set $armed = 0

# HW breakpoint, hit once per licm invocation right after the counter slot is
# zeroed.  Arm the watchpoint only on the crashing frame (deterministic SP).
hbreak *0x10328682
commands
  silent
  if $armed == 0 && $sp == 0x11065478
    set $armed = 1
    set $slot = $sp + 72
    printf "[LW] crashing licm frame: sp=0x%08x slot=0x%08x *slot=0x%08x\n", $sp, $slot, *(unsigned int *)$slot
    # Write-watchpoint on the slot; skip the legit small counter increments so
    # only the garbage-writing store (value > 0x10000) halts us.  No commands ->
    # a true condition stops GDB and falls through to the report block below.
    watch *(unsigned int *)$slot
    set $wpn = $bpnum
    condition $wpn *(unsigned int *)$slot > 0x10000
    printf "[LW] watchpoint #%d armed on 0x%08x (fires when value > 0x10000)\n", $wpn, $slot
  else
    if $armed == 0
      printf "[LW] licm-init other frame: sp=0x%08x (waiting for sp=0x11065478)\n", $sp
    end
  end
  continue
end

# Backstop (plain HW break, no commands -> stops GDB): if execution reaches the
# faulting load, the watchpoint missed the writer.  The report block detects
# this by $pc and prints the real SP so we can adjust the arm condition.
hbreak *0x10328694

printf "[LW] breakpoints installed. `continue`, then type the tcc command on serial.\n"
continue

# ---- control returns here when EITHER the watchpoint or the backstop stops ----
if $pc == 0x10328694
  printf "\n[LW] !! reached faulting ldrb WITHOUT catching the writer\n"
  printf "[LW]    sp=0x%08x  slot(sp+72)=0x%08x  *slot=0x%08x  r2(idx)=0x%08x\n", $sp, $sp+72, *(unsigned int *)($sp+72), $r2
  printf "[LW]    -> the crashing frame SP differs from 0x11065478; set the arm\n"
  printf "[LW]       condition to this sp value and re-run.\n"
  bt
else
  printf "\n[LW] ================ SLOT SMASHED — corruptor caught ================\n"
  printf "[LW] store PC = 0x%08x   (ELF 0x%06x)\n", $pc, $pc - 0x101E9024
  printf "[LW] store LR = 0x%08x   (ELF 0x%06x)\n", $lr, $lr - 0x101E9024
  printf "[LW] slot 0x%08x now = 0x%08x\n", $slot, *(unsigned int *)$slot
  info registers
  printf "[LW] backtrace:\n"
  bt
  printf "[LW] disassembly around the storing PC:\n"
  x/10i $pc - 16
end
printf "[LW] (quitting; symbolize ELF offset host-side via arm-none-eabi-addr2line)\n"
quit
