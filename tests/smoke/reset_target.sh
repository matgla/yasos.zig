#!/bin/bash

# Rescue DP first to clear QSPI Quad I/O mode left by overclock firmware.
openocd -f interface/cmsis-dap.cfg -f target/rp2350-rescue.cfg \
    -c "adapter speed 5000" -c "init" -c "exit" 2>/dev/null || true
sleep 1

openocd -f interface/cmsis-dap.cfg -f target/rp2350.cfg \
    -c "adapter speed 20000" -c "init" -c "reset halt" -c "reset run" -c "exit"