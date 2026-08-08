# Toybox parse_optflaglist crash debug script
# Usage: (gdb) source scripts/toybox_debug.gdb
#        (gdb) toybox-setup
#        then type "ls" in yasos shell
#        (gdb) continue
#        when breakpoint hits:
#        (gdb) walk-opts

# Load symbols for the 2nd ls invocation addresses from run.txt
define toybox-setup
  add-symbol-file apps/toybox/toybox.elf 0x103684e0 -s .data 0x1102a000 -s .bss 0x11030ad8 -s .got 0x11032c60 -s .plt 0x103aa710
  add-symbol-file libs/libc/build/libc.so.elf 0x10181c40 -s .data 0x11025000 -s .bss 0x11026740 -s .got 0x11027448
  echo Symbols loaded. Now use one of the strategies below.\n
end

# --- Strategy A: Hardware watchpoint on the node whose next gets corrupted ---
# First we need to know which node. From the crash, fp=0xF0000000.
# That value came from loading opt->next at 0x110E.
# Use: toybox-watch-node <addr>  after walk-opts identifies the last good node.

# --- Strategy B: Break at crash site, dump everything ---
# The crash PC is at offset 0x1232. Use 'hbreak' for hardware breakpoint.
define toybox-catch-crash
  # Hardware breakpoint at crash instruction: ldr.w ip, [r1]
  # offset 0x1232 + 0x103684e0 = 0x10369712
  hbreak *0x10369712
  echo Hardware breakpoint at crash site. Type 'continue', run 'ls'.\n
  echo When it hits, type 'crash-check' to see if fp is corrupt yet.\n
end

# Check if we're about to crash (fp is garbage) or if this is a normal iteration
define crash-check
  printf "fp (opt) = 0x%08x\n", $r11
  printf "r1 (opt+8) = 0x%08x\n", $r1
  if $r11 < 0x11000000
    if $r11 != 0
      printf "*** fp IS CORRUPT! Examine below: ***\n"
      printf "r2 (ll_lo) = 0x%08x\n", $r2
      printf "r3 (ll_hi) = 0x%08x\n", $r3
      printf "r4 (gof)   = 0x%08x\n", $r4
      printf "r5 (options) = 0x%08x\n", $r5
      printf "r6 = 0x%08x\n", $r6
      printf "r7 (frame) = 0x%08x\n", $r7
      printf "r8 = 0x%08x\n", $r8
      printf "sp = 0x%08x\n", $sp
      # Dump stack around the 64-bit shift area
      printf "\nStack [r7-160..r7-100]:\n"
      x/16x $r7-160
      printf "\nStack [r7-240..r7-180]:\n"
      x/16x $r7-240
    else
      printf "fp is NULL (end of list) - this is normal\n"
    end
  else
    printf "fp looks valid. Type 'continue' to skip to next hit.\n"
  end
end

# --- Strategy C: Break at both fp-load points, unconditional ---
# Use with 'commands' to auto-continue if fp looks valid.
define toybox-trace-fp
  # Break after initial opt = gof->opts
  # offset 0x1094 + base = 0x10369574
  hbreak *0x10369574
  commands
    silent
    if $r11 != 0 && ($r11 < 0x11000000 || $r11 > 0x11800000)
      printf "*** CORRUPT at initial load! fp=0x%08x ***\n", $r11
    else
      continue
    end
  end
  # Break after opt = opt->next
  # offset 0x1112 + base = 0x103695F2
  hbreak *0x103695F2
  commands
    silent
    if $r11 != 0 && ($r11 < 0x11000000 || $r11 > 0x11800000)
      printf "*** CORRUPT at opt->next! fp=0x%08x, loaded from [r6]=0x%08x ***\n", $r11, $r6
      printf "r6 node dump:\n"
      x/12x $r6
    else
      continue
    end
  end
  echo Tracing fp loads. Type 'continue', run 'ls'. Will auto-stop on corruption.\n
end

# --- Strategy D: Break at loop init, walk the list ---
define toybox-break-init
  # offset 0x1086 + base = 0x10369566
  hbreak *0x10369566
  echo Break at for-loop init. Type 'continue', run 'ls', then 'walk-opts'.\n
end

# Walk the opts linked list from gof->opts (using r4 register)
define walk-opts
  set $opt = *(unsigned int*)((unsigned int)$r4 + 16)
  set $i = 0
  while $opt != 0
    set $next = *(unsigned int*)$opt
    set $c = *(int*)($opt + 8)
    printf "node %2d: addr=0x%08x  next=0x%08x  c=%d ('%c')\n", $i, $opt, $next, $c, $c
    set $opt = $next
    set $i = $i + 1
    if $i > 50
      printf "STOPPED: too many nodes, possible loop\n"
      loop_break
    end
  end
  printf "Total: %d nodes\n", $i
end

# Walk the opts linked list from a given address
# Usage: walk-opts-from 0x1103ea70
define walk-opts-from
  set $opt = (unsigned int)$arg0
  set $i = 0
  while $opt != 0
    set $next = *(unsigned int*)$opt
    set $c = *(int*)($opt + 8)
    printf "node %2d: addr=0x%08x  next=0x%08x  c=%d ('%c')\n", $i, $opt, $next, $c, $c
    set $opt = $next
    set $i = $i + 1
    if $i > 50
      printf "STOPPED: too many nodes, possible loop\n"
      loop_break
    end
  end
  printf "Total: %d nodes\n", $i
end

# Dump registers + stack at crash
define crash-info
  info registers
  printf "opt (fp/r11) = 0x%08x\n", $r11
  printf "ll = r2:r3 = 0x%08x:%08x\n", $r3, $r2
  x/20x $r7-256
end

# Examine a single opts node
define show-opt
  if $argc == 1
    set $addr = (unsigned int)$arg0
    printf "  next  = 0x%08x\n", *(unsigned int*)$addr
    printf "  arg   = 0x%08x\n", *(unsigned int*)($addr + 4)
    printf "  c     = %d (0x%02x)\n", *(int*)($addr + 8), *(int*)($addr + 8)
    printf "  flags = %d\n", *(int*)($addr + 12)
    printf "  dex[0]= 0x%016llx\n", *(unsigned long long*)($addr + 16)
    printf "  dex[1]= 0x%016llx\n", *(unsigned long long*)($addr + 24)
    printf "  dex[2]= 0x%016llx\n", *(unsigned long long*)($addr + 32)
  else
    printf "Usage: show-opt <address>\n"
  end
end
