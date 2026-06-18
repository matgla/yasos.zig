set pagination off
set confirm off
target remote :1234
break module.zig:200
commands
  silent
  printf "GENTHUNK index=%d datalen=%d\n", index, thunks.data.len
  continue
end
break module.zig:239
commands
  silent
  printf "GENLAZY count=%d datalen=%d\n", self.lazy_thunks.?.count, self.lazy_thunks.?.thunk_data.len
  continue
end
break irq_hard_fault
commands
  printf "=== HARDFAULT ===\n"
  bt
end
continue
quit
