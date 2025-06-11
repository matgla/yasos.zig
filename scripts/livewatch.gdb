# Live watchpoint to catch the PCH-auto heap corruptor in the act.
#
# Preconditions (set up by the orchestration before sourcing this):
#   - target connected (extended-remote :3333), board reset-halted
#   - yasld-load already run so symbols map to runtime load addresses
#   - a serial sender is waiting in the background and will type the tcc
#     command once the board boots to the shell prompt
#
# Strategy: HW-break at tcc_pch_auto_load_index, let it build the entries,
# then set write watchpoints on entry[0]'s pointer fields and continue so the
# out-of-bounds writer faults/stops AT ITS OWN PC.
set pagination off
set confirm off
set height 0
set width 0

# HW breakpoint survives the dynamic yasld load of tcc into PSRAM.
hbreak tcc_pch_auto_load_index
printf "[LW] continuing to boot + run tcc...\n"
continue

# --- stopped at tcc_pch_auto_load_index: read s1 from DWARF local ---
set $s1 = s1
printf "[LW] at load_index, s1=%p\n", $s1
finish

printf "[LW] after load_index: auto_pch_entries=%p nb=%d\n", $s1->auto_pch_entries, $s1->nb_auto_pch_entries
set $i = 0
while $i < $s1->nb_auto_pch_entries
  printf "[LW]   entry[%d] hp=%p pn=%p\n", $i, $s1->auto_pch_entries[$i].header_path, $s1->auto_pch_entries[$i].pch_name
  set $i = $i + 1
end

# Watch entry[0]'s two pointer fields for the corrupting write.
watch -location $s1->auto_pch_entries[0].pch_name
watch -location $s1->auto_pch_entries[0].header_path
printf "[LW] watchpoints armed; continuing to catch the corruptor...\n"
continue

printf "\n[LW] ===== WATCHPOINT HIT — corruptor caught =====\n"
info registers pc lr
printf "[LW] backtrace:\n"
bt
printf "[LW] disas around PC:\n"
x/6i $pc-8
continue
printf "[LW] (second hit)\n"
info registers pc lr
bt
quit
